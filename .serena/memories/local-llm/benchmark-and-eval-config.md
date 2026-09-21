# local_LLM benchmark & eval configuration

## How the stack is driven (verified 2026-09-06)

- `scripts/benchmark.sh` reads NO config file. Inputs: positional args (iterations, output_file, context_depth), env vars `SERVER_URL` (default http://localhost:8080) and `MODEL_NAME` (default local-model), plus hardcoded prompts/constants in the script.
- The admin container overrides SERVER_URL to `http://llm-server:8080` on the docker network; humans on the host use the default.
- `scripts/llm-eval.py` follows the same convention (SERVER_URL, MODEL_NAME env vars).
- Runtime state (not config) is read live via `docker inspect llm-server` and `nvidia-smi`.

## Habits to keep

- Benchmark measures SPEED only (tok/s, VRAM). Quality is measured by `scripts/llm-eval.py` against `evals/eval-set.json`. Never claim a model is "better" from benchmark.sh alone.
- Eval results land in `evals/results/`; benchmark results in `benchmarks/`.
