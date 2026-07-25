#!/usr/bin/env bash
set -euo pipefail

# Standalone fallback: runs llm-server directly via `docker run`, without
# the rest of the stack (searxng/openwebui/dashy/caddy). Reads the same
# .env as deployments/compose.yml -- for the full stack, use stack-up.sh
# instead.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="$DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

MODE="${1:-}"
if [[ "$MODE" == "--help" || "$MODE" == "-h" ]]; then
  cat <<EOF
Usage: $(basename "$0") [model-filename.gguf]

Reads MODEL_FILE/NGL/N_CPU_MOE/CONTEXT_SIZE/THREADS/LLM_CPUSET from .env
(see .env.example) -- or pass a .gguf filename to override MODEL_FILE for
this one run.

Examples:
  ./docker-run.sh                  # uses MODEL_FILE from .env
  ./docker-run.sh MyModel.gguf     # override for this run
EOF
  exit 0
fi

MODEL="${MODE:-${MODEL_FILE:?Set MODEL_FILE in .env, or pass a .gguf filename as an argument}}"
NGL="${NGL:-99}"
N_CPU_MOE="${N_CPU_MOE:-0}"
CONTEXT_SIZE="${CONTEXT_SIZE:-8192}"
THREADS="${THREADS:-4}"
LLM_CPUSET="${LLM_CPUSET:-}"

if [[ ! -f "$DIR/models/$MODEL" ]]; then
  echo "Error: $DIR/models/$MODEL not found." >&2
  exit 1
fi

docker rm -f llm-server >/dev/null 2>&1 || true

# Cgroup-level CPU restriction, same mechanism as deployments/compose.yml's
# `cpuset:` -- more reliable than llama.cpp's own -Cr/--cpu-strict flags,
# which don't actually restrict the OS-level affinity mask. See README.md
# "Tuning".
CPUSET_ARGS=()
if [[ -n "$LLM_CPUSET" ]]; then
  CPUSET_ARGS=(--cpuset-cpus "$LLM_CPUSET")
fi

docker run -d --name llm-server --gpus all --restart unless-stopped \
  "${CPUSET_ARGS[@]}" \
  -e GGML_CUDA_GRAPH_OPT=1 \
  -v "$DIR/models":/models -p 8080:8080 \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
  -m "/models/$MODEL" \
  -ngl "$NGL" --n-cpu-moe "$N_CPU_MOE" -c "$CONTEXT_SIZE" --parallel 1 \
  -b 4096 -ub 2048 -t "$THREADS" --no-mmap --flash-attn on --jinja \
  --cache-type-k q8_0 --cache-type-v q8_0 --metrics \
  --host 0.0.0.0 --port 8080

echo "llm-server started ($MODEL). Follow logs with: docker logs -f llm-server"
