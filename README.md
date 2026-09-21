# local_LLM

A self-hostable, private local LLM stack: [`llama.cpp`](https://github.com/ggml-org/llama.cpp) serving a GGUF model, an [OpenWebUI](https://github.com/open-webui/open-webui) chat interface, [SearXNG](https://github.com/searxng/searxng) for anonymous web search, a [Dashy](https://dashy.to) portal, and [Caddy](https://caddyserver.com) terminating HTTPS for all of it. Runs entirely in Docker — no data leaves the machine, no cloud dependency, no API costs.

Generic and portable — no assumed hardware, model, or domain. See [`prompt.md`](prompt.md) to have an AI assistant size a model to your actual GPU/CPU/RAM and write your `.env`.

> **This repository is 100% AI-generated** (code, configuration, and documentation), built and maintained through Claude Code.

## Requirements

- Docker + [`nvidia-container-toolkit`](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- An NVIDIA GPU with enough VRAM for your chosen model
- A `.gguf` model file

## Project structure

| Directory | Contents |
|---|---|
| `deployments/` | `compose.yml` — the whole stack, parameterized via `.env`. `compose.monitoring.yml` and `compose.admin.yml` are optional add-ons |
| `scripts/` | Entrypoints and utilities (`stack-up.sh`, `generate-local-ca.sh`, `benchmark.sh`, `detect-hardware.sh`, `tune-system.sh`, `adaptive-power.sh`, ...) |
| `configs/` | Config for the scripts above that need more than an env var — currently just `adaptive-power.conf` |
| `init/` | systemd unit(s) installed by `scripts/tune-system.sh` — currently just `adaptive-power.service` |
| `admin/` | Optional admin panel — Go source + Dockerfile, see "Admin panel" below |
| `docs/` | API reference |
| `portal/`, `searxng/`, `certs/`, `models/`, `openwebui-data/`, `benchmarks/` | Per-service config/data. `.example` templates are tracked; real generated files are git-ignored |

## Quickstart

```bash
mkdir -p models
cp /path/to/your-model.gguf models/

cp .env.example .env
# edit .env: set MODEL_FILE at minimum

./scripts/generate-local-ca.sh yourdomain.home   # required — generates HTTPS certs + config
./scripts/stack-up.sh
```

`yourdomain.home` can be any name, or `localhost` if you don't want a custom domain — see "Custom domain + HTTPS" below.

## Architecture

Five services on one Docker network. Caddy is the sole entry point — path-routed under `:443` (`/` Dashy, `/search` SearXNG, `/llm` the API, `/obs` Grafana if monitoring is enabled, `/admin` the admin panel if enabled), except OpenWebUI which keeps its own port (`:3000`) since its frontend doesn't support subpath routing. `llm-server` (llama.cpp, chosen over vLLM for finer VRAM control) additionally exposes `127.0.0.1:8080` for local benchmarking only — unreachable from the LAN.

See [`prompt.md`](prompt.md)'s environment diagram (`portal/docs/environment.html`) for the full picture.

## Swapping the model

Set `MODEL_FILE` in `.env` to any `.gguf` file in `models/`. Three more variables matter:

- **`N_CPU_MOE`** — for Mixture-of-Experts models, offloads this many expert layers to CPU/RAM (no-op for dense models). MoE models tolerate CPU offload far better than dense ones, since only a few experts activate per token. Rule of thumb: (file size in GB) ÷ (total expert layers) ≈ GB/layer; pick a value leaving ~1-2GB VRAM headroom.
- **`CONTEXT_SIZE`** — KV-cache window; VRAM cost scales with this regardless of actual use.
- **`NGL`** — GPU layer count, default `99` (safely means "all layers" for any model).

## Tuning

- **`LLM_CPUSET`** pins inference to specific CPU cores via Docker's cgroup `cpuset`, more reliable than llama.cpp's own affinity flags. Only worth setting on a hybrid P-core/E-core CPU, and only after measuring — don't assume which cores help.
- **`scripts/tune-system.sh`** (optional, `sudo`) — the second step after `detect-hardware.sh`: generic Linux + NVIDIA host tuning (CPU governor not fought by `power-profiles-daemon`/`tuned`, `vm.swappiness`/`vm.max_map_count`/`vm.overcommit_memory`, NVIDIA persistence mode, Transparent Huge Pages). Nothing in it is specific to any one GPU/CPU model.
- **`scripts/adaptive-power.sh`** (optional, installed by `tune-system.sh` if `configs/adaptive-power.conf` exists) — an event-driven daemon that boosts CPU governor/EPP/GPU clock only while something is actually using the GPU (`llm-server`'s own log for fast reaction, a coarse utilization poll as a fallback so a different GPU job isn't left throttled), and drops back to idle otherwise. Worth it if idle power/fan noise matters to you; skip it if not. Config is hardware-specific — `cp configs/adaptive-power.conf.example configs/adaptive-power.conf` and replace the example's wattages/clocks with your own, derived like this:

  ```bash
  ./scripts/power-cap-sweep.sh gpu   # finds YOUR GPU's safe power floor
  ```

  Use that floor (with headroom, not right at it) as `POWER_LIMIT_IDLE`, and your GPU's stock power limit as `POWER_LIMIT_ACTIVE`. The example file explains each value and where it came from on the machine it was measured on.

## Family access

| Service | URL | Auth |
|---|---|---|
| Portal | `https://<your-domain>/` | None by default |
| OpenWebUI (chat) | `https://<your-domain>:3000` | Real login, admin-created accounts (signup disabled) |
| SearXNG (search) | `https://<your-domain>/search/` | None — anonymous by design |
| API | `https://<your-domain>/llm/v1` | None — see `docs/api.md` |

If you change `OPENAI_API_BASE_URL` or `SEARXNG_QUERY_URL` after OpenWebUI has already run once, also run `scripts/bootstrap-openwebui.sh` — OpenWebUI only reads those env vars on first initialization after that.

## Custom domain + HTTPS

`.home`/`.lan`/`.local` domains can't get a real Let's Encrypt certificate — nothing delegates them. `scripts/generate-local-ca.sh <domain>` generates a private root CA + a leaf certificate, giving real (not click-through) HTTPS trust on any device that imports the CA (`certs/ca.crt`):

- **Windows**: double-click `ca.crt` → Install Certificate → Local Machine → "Trusted Root Certification Authorities"
- **macOS**: open `ca.crt` in Keychain Access → System keychain → double-click → "Always Trust"
- **Linux**: `sudo cp ca.crt /usr/local/share/ca-certificates/local-llm-ca.crt && sudo update-ca-certificates` (Firefox needs its own import too)
- **iOS**: AirDrop/email the file → install the profile in Settings → then enable full trust under Certificate Trust Settings
- **Android**: Settings → Security → Encryption & credentials → Install a certificate

Devices without the CA still connect, just with a browser warning. `ca.crt` is also served at `https://<your-domain>/ca.crt`.

Own a real domain instead? A proper Let's Encrypt cert via DNS-01 is possible but not automated here — depends on your DNS provider's API.

## Monitoring

Optional — Prometheus + Grafana + node_exporter + cAdvisor + a GPU exporter, not part of the main stack:

```bash
docker compose -f deployments/compose.yml -f deployments/compose.monitoring.yml up -d
```

Open `https://<your-domain>/obs/` (default login `admin`/`admin` — change `GRAFANA_ADMIN_PASSWORD` before exposing this beyond localhost). Five dashboards ship out of the box: **System Overview** (start here — Golden Signals + RED + USE at a glance), plus per-source LLM Server, Caddy, Node Exporter, and cAdvisor dashboards.

cAdvisor needs read-only `docker.sock` access to introspect containers, and a `fs.inotify.max_user_instances` of at least a few thousand — raise it with `echo 'fs.inotify.max_user_instances=4096' | sudo tee /etc/sysctl.d/99-inotify.conf && sudo sysctl --system` if it crash-loops on startup.

**After any host NVIDIA driver update, restart the GPU exporter**: `docker restart gpu-exporter`. It holds an NVML handle opened against the driver that was loaded when it started — a host driver update/reload doesn't kill the container, but leaves that handle stale, so it starts failing every scrape with `Failed to initialize NVML: Unknown Error` while `nvidia-smi` on the host itself keeps working fine. Symptom: GPU utilization/saturation panels go flat/empty in Grafana with no container crash to point at it.

## Admin panel

Optional — a small Go web app to switch the active model and trigger `detect-hardware.sh`/`benchmark.sh` from a browser instead of the CLI:

```bash
docker compose -f deployments/compose.yml -f deployments/compose.admin.yml up -d
```

Open `https://<your-domain>/admin/` — gated by Caddy `basic_auth`, not by the app itself. Before bringing it up, set in `.env`: `ADMIN_USERNAME`/`ADMIN_PASSWORD_HASH` (hash with `docker run --rm caddy:2.9.1-alpine caddy hash-password --plaintext 'your-password'`, doubling every `$` in the result before pasting it in), `HOST_REPO_DIR` — this repo's absolute path on the host, required because the app drives `docker compose` from inside its own container, and bind-mount paths must resolve against the real host filesystem, not the container's own view of it — and `OPENWEBUI_ADMIN_EMAIL`/`OPENWEBUI_ADMIN_PASSWORD`, the same OpenWebUI admin account `scripts/bootstrap-openwebui.sh` uses. If your host user's UID isn't `1000` (`id -u` to check), also set `ADMIN_UID` before building — otherwise the container's writes through its `/repo` bind mount (e.g. `portal/docs/hardware.html`) fail with a permission error.

**Docker access is scoped, not raw**: the `admin` container itself has **no access to `docker.sock`**. A dedicated `docker-socket-proxy` service holds the only (read-only) mount of the real socket and exposes a restricted, allowlisted subset of the Docker API over the network instead — containers/images/networks/volumes and start/stop/restart are allowed (what `docker compose up -d llm-server` needs); `exec` into any container, secrets, and everything Swarm-related are denied. See the diagram at `/docs/environment.html` for exactly what's allowed/denied.

**Switching models updates two consumers, one automatically and one by hand.** OpenWebUI is synced by the admin panel itself — it calls OpenWebUI's API right after the restart to set `function_calling: legacy` on the new model's ID, the same fix `bootstrap-openwebui.sh` applies, without which OpenWebUI's web search silently breaks for that model. OpenCode's config lives in the operator's own home directory (`~/.config/opencode/opencode.json`), not reachable from inside the container, so after switching, run `./scripts/sync-opencode-config.sh` on the machine OpenCode runs on — it reads the new `MODEL_FILE` from `.env`, infers the instruct/coder profile from the filename, and updates just the `model` key and that one model entry in place. It's a no-op (exits cleanly) if OpenCode isn't installed there.

## OpenCode setup

[OpenCode](https://opencode.ai) connects to the API endpoint above like any OpenAI-compatible client. It needs an explicit `"tool_call": true` per model — without it, OpenCode falls back to text-based tool-call emulation instead of the model's real structured tool calls:

```json
{
  "provider": {
    "local-llama": {
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "https://<your-domain>/llm/v1" },
      "models": {
        "your-model-name": {
          "tool_call": true,
          "limit": { "context": 8192, "output": 4096 }
        }
      }
    }
  }
}
```

## License

[PolyForm Noncommercial 1.0.0](LICENSE) — free to use, modify, and redistribute for any noncommercial purpose. Not licensed for commercial use.
