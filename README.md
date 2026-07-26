# local-llm

A self-hostable, private local LLM stack: [`llama.cpp`](https://github.com/ggml-org/llama.cpp) serving a GGUF model, an [OpenWebUI](https://github.com/open-webui/open-webui) chat interface, [SearXNG](https://github.com/searxng/searxng) for anonymous web search, a [Dashy](https://dashy.to) portal tying it together, and [Caddy](https://caddyserver.com) terminating HTTPS for all of it. Runs entirely in Docker — no data leaves the machine, no cloud dependency, no API costs.

This is a generic, portable base — it doesn't assume any specific hardware, model, or domain. Everything hardware-specific belongs in your own deployment: what CPU cores to pin, how much VRAM you have, what model fits it. See "Tuning" below for how this project's own hardware-specific tuning ended up living as a separate project entirely.

## Requirements

- Docker + [`nvidia-container-toolkit`](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) (for `--gpus all` support)
- An NVIDIA GPU with enough VRAM for your chosen model (see "Swapping the model" below)
- A `.gguf` model file

## Project Structure

Follows the layout convention in `fmt/go/project_layout.md` (a platform-engineering reference library this project happens to sit alongside — see `fmt/overlays/heggli/homelab/local-LLM/README.md` for the reasoning, not required reading to use this repo):

| Directory | Contents |
|---|---|
| `deployments/` | `compose.yml` — the whole stack, parameterized via `.env` |
| `scripts/` | Every entrypoint and utility script (`stack-up.sh`, `docker-run.sh`, `generate-local-ca.sh`, `benchmark.sh`, `detect-hardware.sh`, ...) |
| `docs/` | `api.md` — API reference |
| `portal/`, `searxng/`, `certs/`, `models/`, `openwebui-data/`, `benchmarks/` | Live per-service config/data. `.example` templates are tracked; the real generated files are git-ignored (see "Quickstart") |

**Gotcha — editing single-file bind mounts**: `compose.yml` bind-mounts individual files (`portal/conf.yml`, `certs/Caddyfile`, cert files) and one directory (`portal/docs/`). Docker binds these to a specific inode, not the path. An editor that writes atomically (write a temp file, then rename over the original — the safe-write pattern most editors use) replaces the inode, silently breaking the mount: the container keeps serving the old, now-unlinked file. Fix is always the same — restart the container after editing (`docker restart <service>`), don't assume a live bind mount means live-reloading.

## Quickstart

**Don't know which model fits your hardware, or how to set `N_CPU_MOE`/`NGL`/`CONTEXT_SIZE`?** Point an AI coding assistant at [`prompt.md`](prompt.md) — it's a runbook for detecting your actual GPU/CPU/RAM and reasoning from that to a real `MODEL_FILE` choice and tuned `.env`, not generic advice.

```bash
# 1. Put your model in models/
mkdir -p models
cp /path/to/your-model.gguf models/

# 2. Configure
cp .env.example .env
# edit .env: set MODEL_FILE at minimum

# 3. (Optional) Set up your own domain + HTTPS -- otherwise the stack is
#    HTTP-only on localhost. See "Custom domain + HTTPS" below.
./scripts/generate-local-ca.sh yourdomain.home

# 4. Bring it up
./scripts/stack-up.sh
```

## Architecture

Five services, one Docker network:

- **`llm-server`** — `llama.cpp`'s official CUDA server image. Not vLLM: llama.cpp gives fine-grained VRAM control (layer offload, KV-cache quantization) and avoids CUDA toolkit version hell on the host.
- **`searxng`** — anonymous metasearch, no accounts, no tracking. Powers OpenWebUI's web-search feature.
- **`openwebui`** — the chat UI, with real login (family/team use — see "Family Access").
- **`dashy`** — a portal linking everything together.
- **`caddy`** — TLS termination for all of the above. None of the other 4 services publish a host port directly — Caddy is the only thing bound to a host-facing port, terminating HTTPS and reverse-proxying internally. The plain-HTTP ports aren't reachable in parallel; hitting them returns a TLS-required error, not a fallback response.

## Swapping the model

Set `MODEL_FILE` in `.env` to any `.gguf` file placed in `models/`. Three more variables matter:

- **`N_CPU_MOE`** — Mixture-of-Experts models only (a no-op for dense models). Forces this many expert layers to CPU/RAM instead of GPU. Why this matters: a MoE model activates only a handful of its experts per token (e.g. 8 of 128), so a large MoE model can run *acceptably* even with most of its weights on CPU, because a full pass over all weights never happens. A same-sized dense model would need every weight touched every token — CPU-offloading a dense model tanks throughput in a way MoE tolerates much better. Rule of thumb: expert tensors are typically ~90%+ of a MoE model's total file size; divide (file size in GB) by (total expert layers) for a rough GB-per-layer, then pick a value that leaves ~1-2GB VRAM headroom above what fits.
- **`CONTEXT_SIZE`** — KV-cache context window. VRAM cost scales with this regardless of how much of it you actually use in a given request.
- **`NGL`** — GPU layer count, default 99 (llama.cpp clamps to the model's real layer count, so 99 safely means "as many as exist" for any model).

`--no-mmap`, `--flash-attn on`, and `q8_0` KV-cache quantization are set as defaults in `compose.yml` — generally good choices regardless of model (bypass OS page cache for a measurable prefill boost, reduce KV-cache VRAM, quantized cache with negligible quality loss).

## Tuning

Two levers matter more than most LLM-tuning advice suggests, and they generalize beyond any specific hardware:

- **CPU pinning via Docker's `cpuset:`, not the application's own thread-affinity flags.** llama.cpp's own `-Cr`/`--cpu-strict` flags do *not* reliably restrict the OS-level affinity mask (confirmed by checking `taskset -p` directly on every worker thread — the full, unrestricted core range showed up despite these flags being set). `LLM_CPUSET` in `.env` sets Docker's cgroup-level `cpuset`, which does actually restrict every thread atomically, including ones spawned after the container starts. On a hybrid P-core/E-core CPU (Intel 12th-gen+, most AMD isn't affected), whether pinning helps *at all* — and which cores to pin to — depends entirely on your specific chip; don't assume more threads or "the fast cores" is automatically better without measuring both. On a uniform-core CPU, `LLM_CPUSET` is probably not worth setting.
- **Event-driven power management beats both "always max" and utilization-based polling**, if you're running this on hardware where idle power/noise matters. The pattern: watch the inference server's own log output for real generation activity (not CPU/GPU utilization, which is an unreliable proxy — a GPU can spike to ~99% for under a second during prompt processing and a periodic poll can miss it entirely) and boost CPU governor/GPU clocks only while genuinely generating, dropping back to idle after a cooldown. This project doesn't ship an implementation of that pattern — it's inherently hardware-specific (which sysfs knobs, which GPU clock ranges, whether your CPU even has this kind of governor-scope behavior at all).

**Project history**: this stack was originally built and tuned hard against one specific machine — an Intel Core Ultra 7 265KF (Arrow Lake) + RTX 3080 homelab box. That tuning (the specific core ranges, GPU clock daemon, fan/Super-I/O driver work) turned out not to belong in a project about *running an LLM* — none of it is specific to that, it's specific to *that CPU and that motherboard*. It now lives as its own separate project (a real, if hardware-specific, example of applying the two lessons above) with no technical dependency in either direction — this repo doesn't reference it, and that project's power daemon only relies on a loose runtime convention (a container named `llm-server` existing somewhere), not on this repo's internals.

## Family Access

A Dashy portal ties the stack together for other devices on your network:

| Service | URL | Auth |
|---|---|---|
| Portal | `https://<your-domain>/` | None by default — see `portal/conf.yml.example` if you want Dashy's own (client-side-only) login |
| OpenWebUI (chat) | `https://<your-domain>:3000` | Real login — admin creates each account via Admin Panel → Users. Public signup is off by default (`ENABLE_SIGNUP=False` in `compose.yml`) |
| SearXNG (search) | `https://<your-domain>/search/` | None, deliberately — anonymous utility |
| API | `https://<your-domain>/llm/v1` | None — see `docs/api.md` |

Everything is path-routed under Caddy's single `:443` except OpenWebUI, which keeps its own port — its SvelteKit build has absolute root-relative asset paths baked in at build time, with no subpath support available (checked the whole backend source). SearXNG and Grafana both have real subpath-aware middleware built in, so they work correctly under a path prefix; `llm-server` is a pure REST API with no embedded links, so a stripped prefix is transparent to it either way. See `certs/Caddyfile` for the routing.

**Gotcha, hit more than once**: OpenWebUI uses a "PersistentConfig" pattern where an env var only seeds a setting the *first* time its data volume is initialized — after that, only the database (or the Admin UI) can change it. If you ever change `OPENAI_API_BASE_URL` or `SEARXNG_QUERY_URL` in `compose.yml` after the stack has already run once, the env var change alone won't take effect. `scripts/bootstrap-openwebui.sh` re-applies the settings this project actually needs directly against the database — run it after any topology change (or after a fresh `openwebui-data/` volume) rather than assuming a `compose.yml` edit is enough on its own.

## Custom domain + HTTPS

If your domain isn't publicly delegated (anything ending in `.home`, `.lan`, `.local`, etc. — see [RFC 8375](https://www.rfc-editor.org/rfc/rfc8375) for why `home.arpa.` exists as the standardized alternative to ad-hoc `.home` use), it can never get a normal Let's Encrypt certificate — there's no way to prove ownership of a domain nobody delegates. `scripts/generate-local-ca.sh <domain>` generates a private root CA and a leaf certificate signed by it, real cryptographic trust rather than a click-through-the-warning self-signed setup — but only on devices that have imported the CA (`certs/ca.crt`) as a trusted root:

- **Windows**: double-click `ca.crt` → Install Certificate → Local Machine → "Trusted Root Certification Authorities"
- **macOS**: open `ca.crt` in Keychain Access → System keychain → double-click it → set "Always Trust"
- **Linux**: `sudo cp ca.crt /usr/local/share/ca-certificates/local-llm-ca.crt && sudo update-ca-certificates` (Firefox additionally needs its own import: Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import)
- **iOS**: AirDrop or email `ca.crt` to the device → Settings → General → VPN & Device Management → install the profile → then Settings → General → About → Certificate Trust Settings → enable full trust for it (iOS requires this as a separate step)
- **Android**: Settings → Security → Encryption & credentials → Install a certificate → CA certificate

Devices without the CA installed still connect fine — they just see the usual untrusted-certificate warning. `ca.crt` is also served at `https://<your-domain>/ca.crt` once the stack is up, so people can grab it without filesystem access — see `portal/docs/api.html.example`.

If you own a real registered domain, a proper Let's Encrypt certificate via DNS-01 challenge (no port exposure needed) is possible and removes the per-device install step entirely — not automated by this project, since it depends on your specific DNS provider's API.

## Monitoring

Optional — a lightweight metrics stack (Prometheus + Grafana + node_exporter + cAdvisor + a GPU exporter), not folded into the main `compose.yml` since not everyone running this wants a Grafana instance. The GPU exporter requires an NVIDIA GPU + the NVIDIA container runtime (same requirement as `llm-server` itself); drop the `gpu-exporter` service from `compose.monitoring.yml` if running on other hardware. Bring it up alongside the main stack:

```bash
docker compose -f deployments/compose.yml -f deployments/compose.monitoring.yml up -d
```

Dashboards are provisioned from files (`monitoring/grafana/provisioning/`), not hand-clicked — open `https://<your-domain>/obs/` (default login `admin`/`admin`, set `GRAFANA_ADMIN_PASSWORD` in `.env` before exposing this beyond localhost) and five dashboards are already there:

| Dashboard | Covers |
|---|---|
| **System Overview** | The essential, at-a-glance state of the whole stack — Golden Signals (latency, traffic, errors, saturation) up top, then RED (LLM + Caddy) and USE (host, GPU, containers) underneath. Start here; the other four are for drilling into one source |
| **LLM Server** | `llm-server`'s own `/metrics` (already enabled via `--metrics` in `compose.yml`) — generation/prompt throughput, requests processing/deferred, total tokens |
| **Caddy (response metrics)** | Request rate, status codes, and p50/p95/p99 latency per reverse-proxied route — covers `dashy`/`openwebui`/`searxng` too, since neither has a native `/metrics` of its own |
| **Node Exporter Full** | Host-level CPU, memory, disk, network (the standard community reference dashboard) |
| **Cadvisor exporter** | Per-container CPU/memory/network |

**Things worth knowing before enabling this**:
- **cAdvisor needs read-only `docker.sock` access** to introspect containers — a deliberate exception to this project's usual stance of avoiding it (the Dashy portal explicitly doesn't get it). Everything cAdvisor mounts is read-only and it exposes only its own metrics endpoint, but it's still real introspection capability worth knowing is there.
- **cAdvisor needs a decent `fs.inotify.max_user_instances`** — it opens many inotify watches across every container's cgroups on the host, and can crash on startup with `inotify_init: too many open files` on a low default (128 is Ubuntu's default and not enough once several other things are also running). If you hit this, raise it permanently: `echo 'fs.inotify.max_user_instances=4096' | sudo tee /etc/sysctl.d/99-inotify.conf && sudo sysctl --system`.
- **cAdvisor is pinned to v0.55.1, not the newest release** — v0.49.1 (and anything relying on an older bundled Docker API client) fails to register the docker container factory against modern Docker Engine versions (client v1.41 vs. a v1.44 minimum), and only ever emits raw cgroup metrics with no per-container labels. If cAdvisor's dashboard shows no data, this is the first thing to check (`docker logs cadvisor`).

## OpenCode Setup

[OpenCode](https://opencode.ai) connects to the API endpoint above like any OpenAI-compatible client. One non-obvious gotcha:

The first end-to-end test may fail silently — the model produces text that *looks* like a function call (`<function=name>...`) instead of an actual structured tool call, even though the server's native `tool_calls` support works correctly (verify with a direct `curl` against `/v1/chat/completions` with a `tools` array — if that comes back with a proper `tool_calls` field, the server side is fine).

Two things commonly cause this:
1. **`llama-server` needs `--jinja`** (already set by default in `compose.yml`) to render the model's real chat template and parse its native tool-call format back into a structured response — without it, tool-call-looking text just streams through as literal message content.
2. **OpenCode has an undocumented per-model field**, `provider.<id>.models.<id>.tool_call` (boolean), controlling whether it uses native tool calling or falls back to prompt-based text emulation — not auto-detected for custom/unknown model IDs. Add `"tool_call": true` in `~/.config/opencode/opencode.json`:

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

## Known Pitfalls

- `--flash-attn` requires a value (`on`/`off`/`auto`) in recent llama.cpp versions — no longer a bare flag.
- `llama.cpp` warns about tensor overrides with mmap enabled — always use `--no-mmap` when using `--n-cpu-moe`.
- `llama-bench` without `-d` (depth) tests with near-empty context — KV-cache VRAM appears artificially low. Use `-d <depth>` for realistic measurements.
- `nvidia-smi -ac` (application clocks / "VRAM overclock") is a documented no-op on recent driver versions — reports "deprecated" and doesn't change the measured memory clock. `-lgc` (core clock lock) is real and functional.
- OpenWebUI's web-search feature is only invoked when the model's `function_calling` mode resolves to `"legacy"` — if you enable native tool-calling (`--jinja`) and OpenWebUI starts expecting the *model* to call a `web_search` tool itself instead (which isn't wired up by default), search silently stops working. `scripts/bootstrap-openwebui.sh` forces this back to `"legacy"` via OpenWebUI's own API.
- If you add a healthcheck that hits SearXNG's `/search` endpoint, use a real lightweight path like `/healthz` instead — a search-query-shaped healthcheck fires real queries against real engines on every interval, and will eventually get your IP rate-limited by them.
