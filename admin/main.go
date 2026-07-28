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
	"errors"
	"fmt"
	"html/template"
	"log/slog"
	"net/http"
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
	renderIndex(w, "", "")
}

func handleSwitchModel(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	model := strings.TrimSpace(r.FormValue("model"))
	if model == "" {
		renderIndex(w, "No model selected.", "")
		return
	}
	// Only accept a value that's actually a file in models/ right now --
	// this gets written verbatim into .env, so don't trust arbitrary form
	// input (someone could POST directly, bypassing the dropdown).
	known, err := listModels()
	if err != nil {
		renderIndex(w, fmt.Sprintf("Failed to list models: %v", err), "")
		return
	}
	valid := false
	for _, m := range known {
		if m == model {
			valid = true
			break
		}
	}
	if !valid {
		renderIndex(w, fmt.Sprintf("%q is not a file in models/ -- refusing.", model), "")
		return
	}

	if err := setModelFile(model); err != nil {
		slog.Error("failed to update .env", "error", err)
		renderIndex(w, fmt.Sprintf("Failed to update .env: %v", err), "")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Minute)
	defer cancel()
	out, err := runCompose(ctx, "up", "-d", "llm-server")
	if err != nil {
		slog.Error("failed to recreate llm-server", "error", err)
		renderIndex(w, fmt.Sprintf("Switched MODEL_FILE to %s, but recreating llm-server failed:", model), out)
		return
	}
	renderIndex(w, fmt.Sprintf("Switched to %s and recreated llm-server.", model), out)
}

func handleHardwareScan(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	out, err := runScript(ctx, "detect-hardware.sh")
	if err != nil {
		slog.Error("hardware scan failed", "error", err)
		renderIndex(w, "Hardware scan failed:", out)
		return
	}
	renderIndex(w, "Hardware scan complete -- portal/docs/hardware.html updated.", out)
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
		renderIndex(w, fmt.Sprintf("%q is not a valid iteration count.", iterations), "")
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
		renderIndex(w, "Benchmark failed:", out)
		return
	}
	renderIndex(w, "Benchmark complete.", out)
}

func renderIndex(w http.ResponseWriter, message, output string) {
	models, err := listModels()
	if err != nil {
		slog.Error("failed to list models", "error", err)
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

// runScript runs a script under scripts/ with the given arguments.
func runScript(ctx context.Context, name string, args ...string) (string, error) {
	full := append([]string{filepath.Join("scripts", name)}, args...)
	return run(ctx, nil, "bash", full...)
}

// runScriptWithEnv is runScript plus extra environment variables, appended
// to the process's own environment (os.Environ()) rather than replacing it,
// since the script still needs normal things like PATH.
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
