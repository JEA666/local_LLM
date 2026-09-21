// Command admin serves a small, password-protected control panel for
// local_LLM: switching the active model and triggering the hardware-scan
// and benchmark scripts. Password protection itself is Caddy's job
// (basicauth on the /admin route) -- this binary trusts that any request
// reaching it already passed that gate.
//
// It never reimplements logic that already exists as a shell script or a
// docker compose invocation -- it shells out to the same commands a human
// would run from the CLI, so behavior can't drift from scripts/*.sh or
// deployments/compose.yml.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// repoDir is the local_LLM repo root, bind-mounted into this container.
// Every shelled-out command runs with this as its working directory so
// relative paths (deployments/compose.yml, scripts/*.sh) resolve exactly
// as they would from a human running them at the repo root.
var repoDir = envOr("REPO_DIR", "/repo")

// hostRepoDir is this same repo's absolute path on the HOST, not inside
// this container. `docker compose` runs client-side in here but talks to
// the HOST's daemon via the socket-mounted docker.sock -- relative volume
// paths in compose.yml (./models, ./certs, ...) get resolved against
// --project-directory to build the bind-mount source path sent to that
// daemon, so it must be a real host path, or the daemon bind-mounts an
// empty directory that happens to not exist yet instead of the real one.
var hostRepoDir = envOr("HOST_REPO_DIR", repoDir)

// Compose infers a project name from the working directory's basename when
// none is given -- on the host that's "local_llm" (from the repo folder
// name), but inside this container the repo is mounted at /repo, which
// would infer "repo" instead. Since docker.sock talks to the HOST's
// daemon, a mismatched project name means compose doesn't recognize the
// already-running llm-server as its own and tries to create a duplicate
// with the same container_name, colliding. Pinning it explicitly keeps
// this container's compose invocations talking about the same project
// regardless of the mount path.
var composeProject = envOr("COMPOSE_PROJECT_NAME", "local_llm")

var modelFileRe = regexp.MustCompile(`(?m)^MODEL_FILE=.*$`)
var digitsRe = regexp.MustCompile(`^[0-9]+$`)

// openWebUIBaseURL: same docker network as llm-server (local-llm-net),
// reached directly by container name -- no TLS, no DOMAIN, no private-CA
// trust needed, unlike going through Caddy's public route.
const openWebUIBaseURL = "http://openwebui:8080"

var openWebUIAdminEmail = envOr("OPENWEBUI_ADMIN_EMAIL", "admin@localhost")
var openWebUIAdminPassword = envOr("OPENWEBUI_ADMIN_PASSWORD", "")

type pageData struct {
	Models      []string
	CurrentFile string
	Message     string
	Output      string
}

var indexTmpl = template.Must(template.ParseFiles(filepath.Join(mustGetwd(), "templates", "index.html")))

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", handleIndex)
	mux.HandleFunc("POST /switch-model", handleSwitchModel)
	mux.HandleFunc("POST /hardware-scan", handleHardwareScan)
	mux.HandleFunc("POST /benchmark", handleBenchmark)

	addr := ":" + envOr("PORT", "8080")
	slog.Info("admin panel starting", "addr", addr, "repoDir", repoDir)
	if err := http.ListenAndServe(addr, mux); err != nil {
		slog.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

func handleIndex(w http.ResponseWriter, r *http.Request) {
	renderIndex(w, nil, "", "")
}

func handleSwitchModel(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	// Fetched once and reused for every render in this handler -- the
	// dropdown's contents don't change over the course of one request, so
	// there's no need to re-list models/ on every exit path.
	known, err := listModels()
	if err != nil {
		renderIndex(w, nil, fmt.Sprintf("Failed to list models: %v", err), "")
		return
	}
	model := strings.TrimSpace(r.FormValue("model"))
	if model == "" {
		renderIndex(w, known, "No model selected.", "")
		return
	}
	// Only accept a value that's actually a file in models/ right now --
	// this gets written verbatim into .env, so don't trust arbitrary form
	// input (someone could POST directly, bypassing the dropdown).
	valid := false
	for _, m := range known {
		if m == model {
			valid = true
			break
		}
	}
	if !valid {
		renderIndex(w, known, fmt.Sprintf("%q is not a file in models/ -- refusing.", model), "")
		return
	}

	if err := setModelFile(model); err != nil {
		slog.Error("failed to update .env", "error", err)
		renderIndex(w, known, fmt.Sprintf("Failed to update .env: %v", err), "")
		return
	}

	// Separate timeout budgets -- a large/cold model's compose recreate can
	// itself run close to a shared budget's full length (VRAM load, image
	// warm-up), which previously left little or nothing for the OpenWebUI
	// sync call below and made it fail with a context-deadline error even
	// though the model switch itself had already succeeded.
	composeCtx, composeCancel := context.WithTimeout(r.Context(), 3*time.Minute)
	defer composeCancel()
	out, err := runCompose(composeCtx, "up", "-d", "llm-server")
	if err != nil {
		slog.Error("failed to recreate llm-server", "error", err)
		renderIndex(w, known, fmt.Sprintf("Switched MODEL_FILE to %s, but recreating llm-server failed:", model), out)
		return
	}

	syncCtx, syncCancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer syncCancel()
	msg := fmt.Sprintf("Switched to %s and recreated llm-server.", model)
	if err := syncOpenWebUIModel(syncCtx, model); err != nil {
		slog.Error("failed to sync OpenWebUI model config", "error", err)
		msg += fmt.Sprintf(" WARNING: failed to set OpenWebUI's function_calling for this model (%v) -- web search may silently fail until this is fixed; see scripts/bootstrap-openwebui.sh.", err)
	} else {
		msg += " OpenWebUI's function_calling set to legacy for this model."
	}
	msg += " Also run ./scripts/sync-opencode-config.sh on this machine to update OpenCode's config."
	renderIndex(w, known, msg, out)
}

// syncOpenWebUIModel sets function_calling=legacy on OpenWebUI's model row
// for modelFile, via OpenWebUI's own REST API (not a raw SQL insert, so the
// row gets the exact shape the app expects) -- mirrors
// scripts/bootstrap-openwebui.sh's set_function_calling_legacy exactly.
// OpenWebUI only runs its own backend web-search handler when a model's
// function_calling mode is 'legacy' -- native tool-calling expects the
// *model* to call a web_search tool itself, which isn't wired up, so search
// silently no-ops without this.
//
// TWO INDEPENDENT IMPLEMENTATIONS OF THE SAME API CONTRACT, NOT ONE SHARED
// ONE: this function and bootstrap-openwebui.sh's set_function_calling_legacy
// hit the same endpoints (/auths/signin, /models/create, /models/model/update)
// with the same body shape, including the same access_grants:[] workaround
// for the same upstream OpenWebUI bug. Nothing enforces they stay identical.
// If OpenWebUI's API contract ever changes (a new required field, a renamed
// endpoint, a different cause for the access_grants 500), you MUST update
// both places or they'll silently disagree on how they configure OpenWebUI.
func syncOpenWebUIModel(ctx context.Context, modelFile string) error {
	if openWebUIAdminPassword == "" {
		return errors.New("OPENWEBUI_ADMIN_PASSWORD not set -- see .env.example")
	}
	client := &http.Client{Timeout: 30 * time.Second}

	token, err := openWebUISignIn(ctx, client)
	if err != nil {
		return fmt.Errorf("sign in: %w", err)
	}

	modelID := "/models/" + modelFile
	body, err := json.Marshal(map[string]any{
		"id":        modelID,
		"name":      modelFile,
		"meta":      map[string]any{},
		"params":    map[string]any{"function_calling": "legacy"},
		"is_active": true,
		// Upstream OpenWebUI bug: 'access_grants' defaults to None in the
		// schema, but /model/update re-validates the dumped form and
		// requires a list -- omitting this causes a 500 on update (not
		// create).
		"access_grants": []any{},
	})
	if err != nil {
		return fmt.Errorf("marshal model body: %w", err)
	}

	status, createBody, err := openWebUIPost(ctx, client, token, "/api/v1/models/create", body)
	if err != nil {
		return fmt.Errorf("create model: %w", err)
	}
	if status != http.StatusOK {
		// Non-200 on create usually means the model row already exists (the
		// API has no dedicated status for that), so fall through to update --
		// but keep create's own status/body around. If update fails too,
		// surface both: reporting only update's error would mask a real
		// create-side problem (expired token, a schema change, ...) behind a
		// generic update failure that has nothing to do with the actual cause.
		updatePath := "/api/v1/models/model/update?id=" + url.QueryEscape(modelID)
		updateStatus, updateBody, err := openWebUIPost(ctx, client, token, updatePath, body)
		if err != nil {
			return fmt.Errorf("create model: status %d (%s); update model: %w", status, truncateBody(createBody), err)
		}
		if updateStatus != http.StatusOK {
			return fmt.Errorf("create model: status %d (%s); update model: status %d (%s)",
				status, truncateBody(createBody), updateStatus, truncateBody(updateBody))
		}
	}
	return nil
}

func openWebUISignIn(ctx context.Context, client *http.Client) (string, error) {
	body, err := json.Marshal(map[string]string{
		"email":    openWebUIAdminEmail,
		"password": openWebUIAdminPassword,
	})
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, openWebUIBaseURL+"/api/v1/auths/signin", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("unexpected status %d", resp.StatusCode)
	}
	var parsed struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return "", fmt.Errorf("decode response: %w", err)
	}
	if parsed.Token == "" {
		return "", errors.New("signin returned no token -- check OPENWEBUI_ADMIN_PASSWORD")
	}
	return parsed.Token, nil
}

// openWebUIPost returns the response status and body -- the body is kept
// (not discarded) so a caller chaining a fallback request (create -> update)
// can report the first failure's actual cause if the fallback fails too.
func openWebUIPost(ctx context.Context, client *http.Client, token, path string, body []byte) (int, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, openWebUIBaseURL+path, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	return resp.StatusCode, respBody, nil
}

// truncateBody keeps error messages short -- OpenWebUI error bodies are
// small JSON objects, not something worth dumping at length into logs/UI.
func truncateBody(b []byte) string {
	const max = 200
	s := strings.TrimSpace(string(b))
	if len(s) > max {
		return s[:max] + "..."
	}
	return s
}

func handleHardwareScan(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	out, err := runScriptWithEnv(ctx, nil, "detect-hardware.sh")
	if err != nil {
		slog.Error("hardware scan failed", "error", err)
		renderIndex(w, nil, "Hardware scan failed:", out)
		return
	}
	renderIndex(w, nil, "Hardware scan complete -- portal/docs/hardware.html updated.", out)
}

func handleBenchmark(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	iterations := strings.TrimSpace(r.FormValue("iterations"))
	if iterations == "" {
		iterations = "3"
	}
	if !digitsRe.MatchString(iterations) {
		renderIndex(w, nil, fmt.Sprintf("%q is not a valid iteration count.", iterations), "")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
	defer cancel()
	// llm-server's SERVER_URL default (localhost:8080) is only reachable
	// from the host -- this container reaches it by container name on
	// local-llm-net instead.
	out, err := runScriptWithEnv(ctx, []string{"SERVER_URL=http://llm-server:8080"}, "benchmark.sh", iterations)
	if err != nil {
		slog.Error("benchmark failed", "error", err)
		renderIndex(w, nil, "Benchmark failed:", out)
		return
	}
	renderIndex(w, nil, "Benchmark complete.", out)
}

// renderIndex renders the page. models may be nil if the caller doesn't
// already have a fresh listing on hand (renderIndex fetches it itself in
// that case) -- callers that just called listModels() for their own
// purposes (e.g. handleSwitchModel validating the posted value) pass that
// slice through instead of triggering a second directory read.
func renderIndex(w http.ResponseWriter, models []string, message, output string) {
	if models == nil {
		var err error
		models, err = listModels()
		if err != nil {
			slog.Error("failed to list models", "error", err)
		}
	}
	current, err := currentModelFile()
	if err != nil {
		slog.Error("failed to read current MODEL_FILE", "error", err)
	}

	data := pageData{
		Models:      models,
		CurrentFile: current,
		Message:     message,
		Output:      output,
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := indexTmpl.Execute(w, data); err != nil {
		slog.Error("failed to render template", "error", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
	}
}

// listModels returns every *.gguf filename in models/, sorted.
func listModels() ([]string, error) {
	entries, err := os.ReadDir(filepath.Join(repoDir, "models"))
	if err != nil {
		return nil, fmt.Errorf("read models dir: %w", err)
	}
	var models []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".gguf") {
			models = append(models, e.Name())
		}
	}
	sort.Strings(models)
	return models, nil
}

// currentModelFile reads MODEL_FILE's value out of .env.
func currentModelFile() (string, error) {
	data, err := os.ReadFile(filepath.Join(repoDir, ".env"))
	if err != nil {
		return "", fmt.Errorf("read .env: %w", err)
	}
	match := modelFileRe.Find(data)
	if match == nil {
		return "", errors.New("MODEL_FILE not found in .env")
	}
	return strings.TrimPrefix(string(match), "MODEL_FILE="), nil
}

// setModelFile rewrites MODEL_FILE in .env in place, leaving every other
// line untouched.
func setModelFile(model string) error {
	envPath := filepath.Join(repoDir, ".env")
	data, err := os.ReadFile(envPath)
	if err != nil {
		return fmt.Errorf("read .env: %w", err)
	}
	if !modelFileRe.Match(data) {
		return errors.New("MODEL_FILE not found in .env")
	}
	updated := modelFileRe.ReplaceAll(data, []byte("MODEL_FILE="+model))
	if err := os.WriteFile(envPath, updated, 0o644); err != nil {
		return fmt.Errorf("write .env: %w", err)
	}
	return nil
}

// runCompose runs `docker compose -p local_llm --project-directory
// <hostRepoDir> --env-file <repoDir>/.env -f deployments/compose.yml
// <args...>` from repoDir -- the same invocation scripts/stack-up.sh uses,
// plus -p and a host-real --project-directory (see composeProject/
// hostRepoDir above). --env-file is pinned separately and explicitly
// because compose otherwise looks for .env inside --project-directory,
// which is a host-real path this container's own filesystem doesn't have
// -- only /repo (repoDir) does.
func runCompose(ctx context.Context, args ...string) (string, error) {
	full := append([]string{
		"compose", "-p", composeProject,
		"--project-directory", hostRepoDir,
		"--env-file", filepath.Join(repoDir, ".env"),
		"-f", "deployments/compose.yml",
	}, args...)
	return run(ctx, nil, "docker", full...)
}

// runScriptWithEnv runs a script under scripts/ with the given arguments,
// plus extra environment variables (nil for none) appended to the
// process's own environment (os.Environ()) rather than replacing it, since
// the script still needs normal things like PATH.
func runScriptWithEnv(ctx context.Context, extraEnv []string, name string, args ...string) (string, error) {
	full := append([]string{filepath.Join("scripts", name)}, args...)
	return run(ctx, extraEnv, "bash", full...)
}

func run(ctx context.Context, extraEnv []string, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = repoDir
	if len(extraEnv) > 0 {
		cmd.Env = append(os.Environ(), extraEnv...)
	}
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return buf.String(), err
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func mustGetwd() string {
	wd, err := os.Getwd()
	if err != nil {
		panic(err)
	}
	return wd
}
