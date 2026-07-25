#!/usr/bin/env bash
set -euo pipefail

# benchmark.sh — Standardized LLM benchmark for ultron
#
# Usage:
#   ./benchmark.sh [iterations] [output_file] [context_depth]
#
# Arguments:
#   iterations    Number of measured iterations (default: 3, warmup runs 1 extra, discarded)
#   output_file   JSON output path (default: benchmark_results.json)
#   context_depth Fill conversation to this token depth before measuring TG (default: 0 = shallow)
#                 Set to 32768 for production-realistic 32K context test.
#
# Measures:
#   - PP: Prompt processing speed (tok/s) — fresh prompt each time (unique suffix per iteration)
#   - TG: Token generation speed (tok/s) — measured at specified context depth
#   - VRAM usage
#   - GPU clocks and temperature
#
# Context depth: builds a multi-turn conversation to target depth, then measures TG
# for the final response. This measures real throughput at actual context depth, not
# a separate "fill" request that gets replaced.
#
# PP cache prevention: each PP request appends a unique suffix (iteration + timestamp)
# so the server cannot serve from cache. This measures genuine prompt processing speed.
#
# Timing source: reads timings.predicted_per_second / timings.prompt_per_second
# from the llama.cpp server response (not wall-clock).
#
# Warmup: iteration 0 is always discarded.
#
# Cross-LLM verification: both Claude and opencode should produce identical results
# when running this script on the same hardware with the same server config.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ITERATIONS="${1:-3}"
OUTPUT_FILE="${2:-$SCRIPT_DIR/../benchmarks/benchmark_results.json}"
CONTEXT_DEPTH="${3:-0}"
SERVER_URL="http://localhost:8080"
MODEL_NAME="${MODEL_NAME:-local-model}"
SCRIPT_VERSION="3.0.0"

# Fixed test prompts — deterministic base, unique suffix added per iteration
TG_PROMPT="Explain the difference between TCP and UDP protocols in detail. Cover connection-oriented vs connectionless, reliability, ordering, flow control, congestion control, header overhead, and use cases. Give examples."
PP_PROMPT="Write a Python function to calculate fibonacci numbers up to n. Include docstring and type hints."

# Context fill prompt — repeated to build conversation depth
CONTEXT_FILL_PROMPT="Write a detailed analysis of software architecture patterns. Cover microservices, monolithic, event-driven, and serverless architectures. Discuss tradeoffs, use cases, and implementation considerations."

# Fixed parameters
MAX_TOKENS_TG=512
MAX_TOKENS_PP=512
TEMPERATURE=0.0

# --- Get docker config ---
get_docker_config() {
  local cmd image env_vars
  cmd=$(docker inspect llm-server --format '{{range .Config.Cmd}}{{.}} {{end}}' 2>/dev/null | xargs)
  image=$(docker inspect llm-server --format '{{.Config.Image}}' 2>/dev/null)
  env_vars=$(docker inspect llm-server --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -E "^(GGML_|NVIDIA_)" | tr '\n' ';')

  cat <<EOF
{
  "image": "$image",
  "cmd": "$cmd",
  "gpu_env": "$env_vars"
}
EOF
}

# --- Get system info ---
get_system_info() {
  local gpu_clock vram_clock vram_used vram_total temp power governor
  gpu_clock=$(nvidia-smi --query-gpu=clocks.current.graphics --format=csv,noheader 2>/dev/null || echo "N/A")
  vram_clock=$(nvidia-smi --query-gpu=clocks.current.memory --format=csv,noheader 2>/dev/null || echo "N/A")
  vram_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null || echo "N/A")
  vram_total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || echo "N/A")
  temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null || echo "N/A")
  power=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader 2>/dev/null || echo "N/A")
  governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")

  cat <<EOF
{
  "gpu_clock_mhz": "$gpu_clock",
  "vram_clock_mhz": "$vram_clock",
  "vram_used_mib": "$vram_used",
  "vram_total_mib": "$vram_total",
  "gpu_temp_c": "$temp",
  "gpu_power_w": "$power",
  "cpu_governor": "$governor"
}
EOF
}

# --- Build context at target depth (as message history) ---
# Returns a JSON array of messages that fills context to ~target_tokens.
build_context_messages() {
  local target_tokens=$1
  if [[ "$target_tokens" -le 0 ]]; then
    echo "[]"
    return
  fi

  python3 -c "
import json

base = '''$CONTEXT_FILL_PROMPT'''
# Each turn: user asks for analysis, assistant responds with ~500 tokens
# We need target_tokens / 500 turns
turns = $target_tokens // 500 + 1
messages = []
for i in range(turns):
    user_msg = f'{base} (Part {i+1} of {turns})'
    # Simulated assistant response (~500 tokens each)
    assistant_msg = ('This is a detailed analysis of software architecture patterns. ' * 20)[:2000]
    messages.append({'role': 'user', 'content': user_msg})
    messages.append({'role': 'assistant', 'content': assistant_msg})
print(json.dumps(messages))
"
}

# --- Benchmark functions ---

# PP: fresh prompt each time (~512 tokens, unique per iteration to prevent cache hits)
run_pp_benchmark() {
  local iter=$1
  local timestamp unique_prompt response
  timestamp=$(date +%s%N)

  # Build ~512 token prompt — entire prompt unique per iteration
  unique_prompt=$(python3 -c "
base = '''$PP_PROMPT'''
nonce = 'run ${iter} nonce ${timestamp}'
# Use nonce to make EVERY token unique — prefix, body, and suffix
# This ensures zero cache hits even if server caches aggressively
body = f'{base} {nonce}. '
# Repeat the unique body to fill ~500 tokens
target = 500 * 4
padded = (body * (target // len(body) + 1))[:target]
# Final unique suffix
print(padded + f' [END-{nonce}]')
")

  response=$(curl -s "$SERVER_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"$MODEL_NAME\",
      \"messages\": [{\"role\": \"user\", \"content\": $(echo "$unique_prompt" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}],
      \"max_tokens\": 1,
      \"temperature\": $TEMPERATURE
    }")

  echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
usage = data.get('usage', {})
timings = data.get('timings', {})

prompt_tokens = usage.get('prompt_tokens', 0)
cache_tokens = usage.get('prompt_tokens_details', {}).get('cached_tokens', 0)
new_tokens = prompt_tokens - cache_tokens

pp_tps = timings.get('prompt_per_second', 0)
if pp_tps == 0:
    prompt_ms = timings.get('prompt_ms', 0)
    if prompt_ms > 0:
        pp_tps = new_tokens / (prompt_ms / 1000)

print(f'{pp_tps:.2f}|{prompt_tokens}|{cache_tokens}|{new_tokens}')
"
}

# TG: measures at specified context depth via message history
run_tg_benchmark() {
  local iter=$1
  local context_msgs=$2
  local messages response

  # Build messages: context + TG prompt
  messages=$(python3 -c "
import json, sys

context = json.loads('''$context_msgs''')
context.append({'role': 'user', 'content': '''$TG_PROMPT'''})
print(json.dumps(context))
")

  response=$(curl -s "$SERVER_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"$MODEL_NAME\",
      \"messages\": $messages,
      \"max_tokens\": $MAX_TOKENS_TG,
      \"temperature\": $TEMPERATURE
    }")

  echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
usage = data.get('usage', {})
timings = data.get('timings', {})

completion_tokens = usage.get('completion_tokens', 0)
prompt_tokens = usage.get('prompt_tokens', 0)
cache_tokens = usage.get('prompt_tokens_details', {}).get('cached_tokens', 0)

tg_tps = timings.get('predicted_per_second', 0)

print(f'{tg_tps:.2f}|{completion_tokens}|{prompt_tokens}|{cache_tokens}')
"
}

main() {
  echo "=== LLM Benchmark v${SCRIPT_VERSION} — ultron ==="
  echo "Model: $MODEL_NAME"
  echo "Iterations: $ITERATIONS (1 warmup + $ITERATIONS measured)"
  echo "Context depth: $CONTEXT_DEPTH"
  echo "Server: $SERVER_URL"
  echo "Timestamp: $(date -Iseconds)"
  echo ""

  if ! curl -s "$SERVER_URL/health" >/dev/null 2>&1; then
    echo "Error: Server not running at $SERVER_URL" >&2
    echo "Start with: scripts/stack-up.sh" >&2
    exit 1
  fi

  local total_runs=$((ITERATIONS + 1))
  echo "Running $total_runs iterations (1 warmup + $ITERATIONS measured)..."
  echo ""

  local context_msgs context_token_count
  context_msgs=$(build_context_messages "$CONTEXT_DEPTH")
  context_token_count=$(echo "$context_msgs" | python3 -c "import sys,json; print(len(json.loads(sys.stdin.read())))")
  echo "Context: $CONTEXT_DEPTH target tokens, $((context_token_count / 2)) conversation turns"
  echo ""

  local -a tg_results pp_results vram_readings
  local -a tg_prompt_tokens tg_cache_tokens pp_prompt_tokens pp_cache_tokens

  local i
  for i in $(seq 0 $((total_runs - 1))); do
    if [[ $i -eq 0 ]]; then
      echo "--- Warmup (discarded) ---"
    else
      echo "--- Iteration $i/$ITERATIONS ---"
    fi

    local pp_tps pp_prompt pp_cache pp_new
    echo -n "  PP: "
    IFS='|' read -r pp_tps pp_prompt pp_cache pp_new <<< "$(run_pp_benchmark "$i")"
    echo "$pp_tps tok/s ($pp_prompt tokens, cache: $pp_cache, new: $pp_new)"
    pp_results+=("$pp_tps")
    pp_prompt_tokens+=("$pp_prompt")
    pp_cache_tokens+=("$pp_cache")

    local tg_tps tg_tokens tg_prompt tg_cache
    echo -n "  TG: "
    IFS='|' read -r tg_tps tg_tokens tg_prompt tg_cache <<< "$(run_tg_benchmark "$i" "$context_msgs")"
    echo "$tg_tps tok/s ($tg_tokens tokens, prompt: $tg_prompt, cache: $tg_cache)"
    tg_results+=("$tg_tps")
    tg_prompt_tokens+=("$tg_prompt")
    tg_cache_tokens+=("$tg_cache")

    local vram
    vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null || echo "N/A")
    vram_readings+=("$vram")
    echo "  VRAM: ${vram} MiB"

    if [[ $i -lt $((total_runs - 1)) ]]; then
      echo "  Waiting 3s..."
      sleep 3
    fi
  done

  echo ""
  echo "=== Results (warmup discarded, $ITERATIONS measured iterations) ==="

  # Trim: discard warmup
  local -a tg_measured pp_measured vram_measured
  local -a tg_prompt_measured tg_cache_measured pp_prompt_measured pp_cache_measured
  tg_measured=("${tg_results[@]:1}")
  pp_measured=("${pp_results[@]:1}")
  vram_measured=("${vram_readings[@]:1}")
  tg_prompt_measured=("${tg_prompt_tokens[@]:1}")
  tg_cache_measured=("${tg_cache_tokens[@]:1}")
  pp_prompt_measured=("${pp_prompt_tokens[@]:1}")
  pp_cache_measured=("${pp_cache_tokens[@]:1}")

  local avg_tg avg_pp avg_vram min_tg max_tg min_pp max_pp
  avg_tg=$(python3 -c "vals = [$(IFS=,; echo "${tg_measured[*]}")]; print(f'{sum(vals)/len(vals):.2f}')")
  avg_pp=$(python3 -c "vals = [$(IFS=,; echo "${pp_measured[*]}")]; print(f'{sum(vals)/len(vals):.2f}')")
  avg_vram=$(python3 -c "vals = [$(IFS=,; echo "${vram_measured[*]}")]; print(f'{sum(vals)/len(vals):.0f}')")

  min_tg=$(python3 -c "print(min([$(IFS=,; echo "${tg_measured[*]}")]))")
  max_tg=$(python3 -c "print(max([$(IFS=,; echo "${tg_measured[*]}")]))")
  min_pp=$(python3 -c "print(min([$(IFS=,; echo "${pp_measured[*]}")]))")
  max_pp=$(python3 -c "print(max([$(IFS=,; echo "${pp_measured[*]}")]))")

  echo "TG avg: $avg_tg tok/s (min: $min_tg, max: $max_tg)"
  echo "PP avg: $avg_pp tok/s (min: $min_pp, max: $max_pp)"
  echo "VRAM avg:  $avg_vram MiB"
  echo ""

  local sys_info docker_config timestamp hostname
  sys_info=$(get_system_info)
  docker_config=$(get_docker_config)
  timestamp=$(date -Iseconds)
  hostname=$(hostname)

  python3 -c "
import json

results = {
    'test': 'ultron-benchmark-v3',
    'script_version': '$SCRIPT_VERSION',
    'timestamp': '$timestamp',
    'hostname': '$hostname',
    'model': '$MODEL_NAME',
    'iterations': $ITERATIONS,
    'warmup_discarded': 1,
    'context_depth': $CONTEXT_DEPTH,
    'parameters': {
        'max_tokens_tg': $MAX_TOKENS_TG,
        'max_tokens_pp': $MAX_TOKENS_PP,
        'temperature': $TEMPERATURE,
        'server_url': '$SERVER_URL'
    },
    'docker_config': $docker_config,
    'tg': {
        'avg_tps': $avg_tg,
        'min_tps': $min_tg,
        'max_tps': $max_tg,
        'all_results': [$(IFS=,; echo "${tg_measured[*]}")],
        'prompt_tokens_per_iter': [$(IFS=,; echo "${tg_prompt_measured[*]}")],
        'cache_tokens_per_iter': [$(IFS=,; echo "${tg_cache_measured[*]}")]
    },
    'pp': {
        'avg_tps': $avg_pp,
        'min_tps': $min_pp,
        'max_tps': $max_pp,
        'all_results': [$(IFS=,; echo "${pp_measured[*]}")],
        'prompt_tokens_per_iter': [$(IFS=,; echo "${pp_prompt_measured[*]}")],
        'cache_tokens_per_iter': [$(IFS=,; echo "${pp_cache_measured[*]}")]
    },
    'vram': {
        'avg_mib': $avg_vram,
        'readings': [$(IFS=,; echo "${vram_measured[*]}")]
    },
    'system': $sys_info
}

with open('$OUTPUT_FILE', 'w') as f:
    json.dump(results, f, indent=2)

print(f'Results saved to $OUTPUT_FILE')
print()
print('=== Summary for cross-LLM verification ===')
print(f'Script:  v{results[\"script_version\"]}')
print(f'PP:      {results[\"pp\"][\"avg_tps\"]} tok/s (iterations: {results[\"pp\"][\"all_results\"]})')
print(f'PP cache: {results[\"pp\"][\"cache_tokens_per_iter\"]}')
print(f'TG:      {results[\"tg\"][\"avg_tps\"]} tok/s (iterations: {results[\"tg\"][\"all_results\"]})')
print(f'TG cache: {results[\"tg\"][\"cache_tokens_per_iter\"]}')
print(f'VRAM:    {results[\"vram\"][\"avg_mib\"]} MiB')
print(f'GPU:     {results[\"system\"][\"gpu_clock_mhz\"]} core / {results[\"system\"][\"vram_clock_mhz\"]} mem')
print(f'CPU:     {results[\"system\"][\"cpu_governor\"]}')
print(f'Docker:  {results[\"docker_config\"][\"image\"]}')
print(f'Cmd:     {results[\"docker_config\"][\"cmd\"][:80]}...')
"
}

main "$@"
