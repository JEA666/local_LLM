#!/usr/bin/env bash
set -euo pipefail

# power-cap-sweep.sh — Find the lowest GPU/CPU power limit before LLM
# throughput degrades, by driving benchmark.sh at decreasing power caps.
#
# GPU: nvidia-smi -pl (persistence mode required to hold reliably).
# CPU: Intel RAPL package power limit (PL1 long_term + PL2 short_term, set
#      together to the same value to avoid boost-then-throttle noise) via
#      /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_*_power_limit_uw.
#
# Method: coarse sweep top-down in $COARSE_STEP watts, stop at the first
# level where TG or PP drops more than $THRESHOLD_PCT% below the baseline
# (both at default power). Floor = last level that still passed -- no
# refine pass, so it's precise to +/- $COARSE_STEP W, not exact. GPU is
# swept first (CPU at default), then restored to default before sweeping
# CPU (GPU at default) -- independent floors, not a joint search.
#
# CAUTION: the CPU cap applies to the whole package, not just the cores
# LLM_CPUSET pins inference to (8-19) — it affects every process on this
# machine, not just llama.cpp. Avoid other heavy CPU work during the CPU
# phase, and expect its results to be noisier than the GPU phase's if you
# don't.
#
# CAUTION: nvidia-smi -pl is a device-level cap too, same as the CPU one --
# it throttles the whole GPU, not just llm-server. Avoid other GPU work
# (including things like a remote-desktop session using NVENC) during
# either phase: a throughput drop at a given wattage could be contention
# with that other process, not the cap itself, and would silently produce
# a wrong floor. Every benchmark run in this script checks nvidia-smi's
# compute-apps list against llm-server's PID first and aborts if it finds
# another process there -- override with ALLOW_GPU_CONTENTION=1 if you
# understand the risk and want the numbers anyway.
#
# CAUTION: a second controller can fight this script over the exact same
# knobs without ever showing up as a GPU compute process -- an OS-level
# power daemon (TLP, auto-cpufreq, a laptop power-profile service, or a
# custom systemd unit that reacts to load by calling nvidia-smi -pl /
# writing RAPL sysfs itself) doesn't run *on* the GPU, it just changes the
# same limit out from under you. This script reads back the GPU power
# limit and RAPL cap right after setting them and after every benchmark
# run, and aborts (again overridable with ALLOW_GPU_CONTENTION=1) if either
# one doesn't match what it just set -- that mismatch is the signature of
# exactly this kind of interference. Disable any such service for the
# duration of the sweep.
#
# Needs sudo (nvidia-smi -pl/-pm, writing RAPL sysfs). Restores GPU power
# limit, GPU persistence mode, and CPU power limits to their original
# values on exit, including Ctrl-C.
#
# Usage: ./power-cap-sweep.sh [gpu|cpu|both]   (default: both)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH="$SCRIPT_DIR/benchmark.sh"
RESULTS_DIR="$SCRIPT_DIR/../benchmarks/power-cap-sweep-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR"

PHASE="${1:-both}"

THRESHOLD_PCT=5
COARSE_STEP=20

GPU_MAX=370   # default power limit -- baseline, not the 380W absolute max
GPU_MIN_FLOOR=120

RAPL_DIR="/sys/class/powercap/intel-rapl/intel-rapl:0"
CPU_MAX=250   # current live PL1=PL2, this board's actual default -- not Intel's stock 125W/250W split
CPU_MIN_FLOOR=40

ORIG_CPU_PL1_UW="$(cat "$RAPL_DIR/constraint_0_power_limit_uw")"
ORIG_CPU_PL2_UW="$(cat "$RAPL_DIR/constraint_1_power_limit_uw")"
ORIG_PERSISTENCE_MODE="$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null || echo "Enabled")"
RESTORED=0

restore_power() {
  [[ $RESTORED -eq 1 ]] && return
  RESTORED=1
  echo "Restoring default power limits..."
  sudo nvidia-smi -pl "$GPU_MAX" >/dev/null 2>&1 || true
  if [[ "$ORIG_PERSISTENCE_MODE" == "Disabled" ]]; then
    sudo nvidia-smi -pm 0 >/dev/null 2>&1 || true
  fi
  echo "$ORIG_CPU_PL1_UW" | sudo tee "$RAPL_DIR/constraint_0_power_limit_uw" >/dev/null 2>&1 || true
  echo "$ORIG_CPU_PL2_UW" | sudo tee "$RAPL_DIR/constraint_1_power_limit_uw" >/dev/null 2>&1 || true
}
trap restore_power EXIT INT TERM

# Tracks what this script itself last set, so drift caused by some other
# controller can be told apart from a value we simply haven't set yet.
EXPECTED_GPU_W=""
EXPECTED_CPU_W=""

set_gpu_power() {
  sudo nvidia-smi -pl "$1" >/dev/null
  EXPECTED_GPU_W="$1"
}

# llm-server's host-visible PID, for the compute-apps contention check below.
# The image's ENTRYPOINT execs llama-server directly (no wrapper shell), so
# the container's PID 1 *is* the process nvidia-smi will list -- confirmed
# via `docker inspect --format '{{.State.Pid}}'` matching
# `nvidia-smi --query-compute-apps` for the same PID on this host.
get_llm_server_pid() {
  docker inspect llm-server --format '{{.State.Pid}}' 2>/dev/null || true
}

# Lists any GPU compute process other than the given PID, as "pid<TAB>name<TAB>mem" lines.
other_gpu_processes() {
  local expected_pid="$1"
  nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null \
    | python3 -c "
import sys
expected = '$expected_pid'
for line in sys.stdin:
    parts = [p.strip() for p in line.strip().split(',')]
    if len(parts) < 3:
        continue
    pid, name, mem = parts[0], parts[1], parts[2]
    if pid != expected:
        print(f'{pid}\t{name}\t{mem}')
"
}

# Aborts (unless ALLOW_GPU_CONTENTION=1) if anything besides llm-server is
# running on the GPU -- nvidia-smi -pl caps the whole device, so any other
# compute process contaminates every throughput measurement taken while
# it's active.
check_gpu_exclusive() {
  local expected_pid others
  expected_pid="$(get_llm_server_pid)"
  if [[ -z "$expected_pid" ]]; then
    echo "" >&2
    echo "WARNING: could not determine llm-server's host PID (is the container running?) -- skipping GPU exclusivity check." >&2
    return
  fi

  others="$(other_gpu_processes "$expected_pid")"
  if [[ -n "$others" ]]; then
    echo "" >&2
    echo "WARNING: GPU has compute processes besides llm-server (pid $expected_pid):" >&2
    while IFS=$'\t' read -r pid name mem; do
      echo "  pid=$pid  $name  ($mem)" >&2
    done <<< "$others"
    echo "" >&2
    echo "nvidia-smi -pl caps power for the WHOLE GPU, not per-process -- a throughput" >&2
    echo "drop at a given wattage could be contention with this process, not the cap." >&2
    echo "Results from this run cannot be trusted as an isolated LLM measurement." >&2
    if [[ "${ALLOW_GPU_CONTENTION:-0}" != "1" ]]; then
      echo "" >&2
      echo "Aborting. Stop the other GPU workload, or re-run with ALLOW_GPU_CONTENTION=1 to proceed anyway." >&2
      exit 1
    fi
    echo "ALLOW_GPU_CONTENTION=1 set -- continuing despite contention." >&2
  fi
}

set_cpu_power() {
  local uw=$(( $1 * 1000000 ))
  echo "$uw" | sudo tee "$RAPL_DIR/constraint_0_power_limit_uw" >/dev/null
  echo "$uw" | sudo tee "$RAPL_DIR/constraint_1_power_limit_uw" >/dev/null
  EXPECTED_CPU_W="$1"
}

# Aborts (unless ALLOW_GPU_CONTENTION=1) if the GPU power limit or RAPL cap
# no longer matches what this script itself last set -- see the "second
# controller" CAUTION above. Skips whichever side hasn't been set yet
# (EXPECTED_*_W empty), so it's safe to call before either phase runs.
verify_power_unchanged() {
  local actual
  if [[ -n "$EXPECTED_GPU_W" ]]; then
    actual="$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | cut -d. -f1)"
    if [[ -n "$actual" && "$actual" -ne "$EXPECTED_GPU_W" ]]; then
      warn_power_drift "GPU" "$EXPECTED_GPU_W" "$actual"
    fi
  fi
  if [[ -n "$EXPECTED_CPU_W" ]]; then
    actual=$(( $(cat "$RAPL_DIR/constraint_0_power_limit_uw") / 1000000 ))
    if [[ "$actual" -ne "$EXPECTED_CPU_W" ]]; then
      warn_power_drift "CPU" "$EXPECTED_CPU_W" "$actual"
    fi
  fi
}

warn_power_drift() {
  local kind="$1" expected="$2" actual="$3"
  echo "" >&2
  echo "WARNING: ${kind} power limit is ${actual}W, but this script set it to ${expected}W." >&2
  echo "Something else changed it -- an OS-level power daemon or custom service reacting" >&2
  echo "to load (TLP, auto-cpufreq, a laptop power-profile service, a custom systemd unit)." >&2
  echo "This measurement cannot be trusted: the cap you think you're testing isn't the" >&2
  echo "one that was actually in effect." >&2
  if [[ "${ALLOW_GPU_CONTENTION:-0}" != "1" ]]; then
    echo "" >&2
    echo "Aborting. Disable the other controller, or re-run with ALLOW_GPU_CONTENTION=1 to proceed anyway." >&2
    exit 1
  fi
  echo "ALLOW_GPU_CONTENTION=1 set -- continuing despite drift." >&2
}

# Runs benchmark.sh, returns "tg_avg|pp_avg", saves raw JSON under $RESULTS_DIR
run_bench() {
  local label="$1" iterations="$2"
  local out="$RESULTS_DIR/${label}.json"
  check_gpu_exclusive
  verify_power_unchanged
  "$BENCH" "$iterations" "$out" 0 >/dev/null
  verify_power_unchanged
  python3 -c "
import json
d = json.load(open('$out'))
print(f\"{d['tg']['avg_tps']}|{d['pp']['avg_tps']}\")
"
}

# Prints PASS/FAIL against baseline, returns 0=pass 1=fail via exit code
check_threshold() {
  local tg="$1" pp="$2" base_tg="$3" base_pp="$4"
  python3 -c "
tg, pp, base_tg, base_pp = $tg, $pp, $base_tg, $base_pp
thresh = 1 - $THRESHOLD_PCT / 100
ok = tg >= base_tg * thresh and pp >= base_pp * thresh
print('PASS' if ok else 'FAIL')
exit(0 if ok else 1)
"
}

sweep() {
  local kind="$1" default="$2" floor="$3" set_fn="$4" base_tg="$5" base_pp="$6"
  local level last_pass=$default
  local result tg pp status rc

  echo ""
  echo "=== $kind sweep: ${default}W down to ${floor}W, step ${COARSE_STEP}W (+/- ${COARSE_STEP}W precision) ==="
  level=$(( default - COARSE_STEP ))
  while [[ $level -ge $floor ]]; do
    echo "-- ${kind} ${level}W --"
    "$set_fn" "$level"
    result="$(run_bench "${kind}-${level}w" 2)"
    tg="${result%%|*}"; pp="${result##*|}"
    status="$(check_threshold "$tg" "$pp" "$base_tg" "$base_pp")" && rc=0 || rc=1
    echo "   TG=$tg PP=$pp -> $status"
    if [[ $rc -eq 0 ]]; then
      last_pass=$level
    else
      break
    fi
    level=$(( level - COARSE_STEP ))
  done

  echo "$kind floor: ${last_pass}W (baseline ${default}W, threshold ${THRESHOLD_PCT}% drop, +/- ${COARSE_STEP}W precision)"
  echo "${kind}_floor_w=${last_pass}" >> "$RESULTS_DIR/summary.txt"
  "$set_fn" "$default"
}

main() {
  echo "=== Power-cap sweep — $(hostname) — $(date -Iseconds) ==="
  echo "Results: $RESULTS_DIR"
  sudo -v

  if [[ "$ORIG_PERSISTENCE_MODE" == "Disabled" ]]; then
    echo "GPU persistence mode is off -- nvidia-smi -pl may not hold reliably. Enabling for the duration of this sweep (restored on exit)."
    sudo nvidia-smi -pm 1 >/dev/null
  fi

  echo ""
  echo "=== Baseline (GPU ${GPU_MAX}W / CPU ${CPU_MAX}W, both already default) ==="
  set_gpu_power "$GPU_MAX"
  set_cpu_power "$CPU_MAX"
  local base base_tg base_pp
  base="$(run_bench "baseline" 3)"
  base_tg="${base%%|*}"; base_pp="${base##*|}"
  echo "Baseline TG=$base_tg PP=$base_pp"
  echo "baseline_tg=$base_tg" > "$RESULTS_DIR/summary.txt"
  echo "baseline_pp=$base_pp" >> "$RESULTS_DIR/summary.txt"

  if [[ "$PHASE" == "gpu" || "$PHASE" == "both" ]]; then
    sweep "gpu" "$GPU_MAX" "$GPU_MIN_FLOOR" set_gpu_power "$base_tg" "$base_pp"
  fi

  if [[ "$PHASE" == "cpu" || "$PHASE" == "both" ]]; then
    echo ""
    echo "NOTE: CPU cap applies to the whole package, not just LLM_CPUSET cores -- avoid other heavy CPU load until this phase finishes."
    sweep "cpu" "$CPU_MAX" "$CPU_MIN_FLOOR" set_cpu_power "$base_tg" "$base_pp"
  fi

  restore_power
  echo ""
  echo "=== Done ==="
  cat "$RESULTS_DIR/summary.txt"
  echo "Full per-level results in $RESULTS_DIR/*.json"
}

main
