#!/usr/bin/env bash
set -euo pipefail

# adaptive-power.sh — Adaptive power management for LLM inference
# Event-driven: tails llm-server's own container log and reacts to the exact
# per-request tok/s it reports (the "eval time = ... tokens per second" line),
# rather than polling GPU utilization as the primary signal. Utilization
# polling was tried and found unreliable *for catching this hybrid MoE
# model's own bursty per-token activity* -- see README / plan history for
# the full investigation (2026-07-22). Log-tailing remains the primary
# trigger for that reason.
#
# That log tail only ever sees llm-server, though -- something else loading
# the GPU (a sim/render/photogrammetry job, anything not llm-server) leaves
# the log silent, so without a second signal this daemon would sit in IDLE
# and throttle power/CPU clocks out from under a workload it can't see at
# all (found 2026-09-20, while checking the local_LLM repo for exactly this
# gap). A sustained heavy job's utilization profile isn't the sparse, bursty
# shape that made polling unreliable for the LLM case above, so a coarse
# GPU_UTIL threshold checked every GENERAL_POLL_INTERVAL is a reliable-enough
# fallback for "something is using the GPU" even though it wasn't precise
# enough to replace the log tail for the LLM's own activity.
#
# Boost is binary, not graduated: any detected generation event (llm-server
# log line, or GPU utilization above GENERAL_GPU_UTIL_THRESHOLD from
# anything else) means real work is happening (quiet-mode throughput, ~13
# tok/s, is categorically too slow to be worth staying in), so PERFORMANCE
# mode engages immediately. IDLE is entered after COOLDOWN_TIME seconds pass
# with no activity from either signal.
#
# Usage:
#   ./adaptive-power.sh              # Run as daemon (normal mode)
#   ./adaptive-power.sh --status     # Show current state
#   ./adaptive-power.sh --force-performance  # Force performance mode
#   ./adaptive-power.sh --force-idle         # Force idle mode
#   ./adaptive-power.sh --force-auto         # Return to automatic mode
#
# Requires: nvidia-smi, docker, bash 4+

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/../configs/adaptive-power.conf"

# --- Load configuration ---
if [[ ! -f "$CONF_FILE" ]]; then
  echo "Error: Configuration file not found: $CONF_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090,SC1091  # dynamic path (SCRIPT_DIR-relative);
# existence already checked above, nothing for shellcheck to statically follow
source "$CONF_FILE"

# --- State definitions ---
STATE_IDLE="IDLE"
STATE_ACTIVE="ACTIVE"

# --- Global variables ---
CURRENT_STATE="$STATE_IDLE"
STATE_SINCE=$(date +%s)
LAST_ACTIVITY_TS=$(date +%s)  # last time EITHER signal (llm-server log or general GPU util) fired
FORCE_MODE=""  # empty = automatic, "performance" or "idle"

# --- Logging ---
log() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] [$level] $msg" | tee -a "$LOG_FILE"
}

# --- Log rotation ---
rotate_log() {
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$size" -gt "$LOG_MAX_SIZE" ]]; then
      mv "$LOG_FILE" "${LOG_FILE}.old"
      log "INFO" "Log rotated (was ${size} bytes)"
    fi
  fi
}

# --- GPU utilities ---
# get_gpu_utilization now doubles as the general-activity fallback signal in
# main_loop (see file header) -- power/temp remain informational only.
get_gpu_utilization() {
  nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d ' '
}

get_gpu_power() {
  nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | tr -d ' '
}

get_gpu_temp() {
  nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d ' '
}

# --- Performance mode ---
set_performance_mode() {
  log "INFO" ">>> Entering PERFORMANCE mode"

  # GPU clock lock -- cheap/harmless, but confirmed NOT the load-bearing part
  # of the fix (governor + affinity contributed the real gain).
  if nvidia-smi -lgc "$GPU_CLOCK_MIN,$GPU_CLOCK_MAX" 2>/dev/null; then
    log "INFO" "  GPU clock locked: ${GPU_CLOCK_MIN}-${GPU_CLOCK_MAX} MHz"
  else
    log "WARN" "  GPU clock lock failed"
  fi

  # Power limit
  if nvidia-smi -pl "$POWER_LIMIT_ACTIVE" 2>/dev/null; then
    log "INFO" "  Power limit: ${POWER_LIMIT_ACTIVE}W"
  else
    log "WARN" "  Power limit failed"
  fi

  # CPU governor -- must be ALL cores, not just the pinned E-cores. Confirmed
  # 2026-07-22: uncore/package clock scales with whole-package activity on
  # this chip, so leaving P-cores in powersave throttles the shared uncore
  # domain even though E-cores individually still hit full clock.
  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo "performance" > "$gov" 2>/dev/null || true
  done

  # EPP (energy_performance_preference) -- separate lever from scaling_governor
  # under intel_pstate/HWP. Never set before 2026-07-22; was sitting at the
  # kernel default (balance_performance) because power-profiles-daemon
  # (which normally sets this) is masked. Match it to performance mode here.
  for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    echo "performance" > "$epp" 2>/dev/null || true
  done

  # Remove CPU frequency limit (allow full boost)
  if [[ "$CPU_MAX_FREQ_ACTIVE" -eq 0 ]]; then
    for freq in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
      hw_max="${freq/scaling_max_freq/cpuinfo_max_freq}"
      if [[ -f "$hw_max" ]]; then
        cat "$hw_max" > "$freq" 2>/dev/null || true
      fi
    done
    log "INFO" "  CPU freq limit: unlimited (full boost)"
  else
    for freq in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
      echo "$CPU_MAX_FREQ_ACTIVE" > "$freq" 2>/dev/null || true
    done
    log "INFO" "  CPU freq limit: ${CPU_MAX_FREQ_ACTIVE} kHz"
  fi
  log "INFO" "  CPU governor: performance (all cores)"
  log "INFO" "  EPP: performance (all cores)"
}

# --- Idle mode ---
set_idle_mode() {
  log "INFO" ">>> Entering IDLE mode"

  # Release GPU clock lock
  if nvidia-smi -rgc 2>/dev/null; then
    log "INFO" "  GPU clock lock released"
  else
    log "WARN" "  GPU clock release failed"
  fi

  # Lower power limit
  if nvidia-smi -pl "$POWER_LIMIT_IDLE" 2>/dev/null; then
    log "INFO" "  Power limit: ${POWER_LIMIT_IDLE}W"
  else
    log "WARN" "  Power limit failed"
  fi

  # CPU governor
  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo "powersave" > "$gov" 2>/dev/null || true
  done

  # EPP -- most conservative preference at idle. This was the gap found
  # 2026-07-22: governor said powersave but EPP stayed at balance_performance
  # (kernel default, never set by us), which under intel_pstate/HWP biases
  # the hardware's own autonomous P-state selection to clock up more eagerly
  # than the governor setting alone implies.
  for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    echo "power" > "$epp" 2>/dev/null || true
  done

  # Limit CPU frequency to reduce heat and fan noise
  for freq in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
    echo "$CPU_MAX_FREQ_IDLE" > "$freq" 2>/dev/null || true
  done
  log "INFO" "  CPU governor: powersave (all cores)"
  log "INFO" "  EPP: power (all cores)"
  log "INFO" "  CPU freq limit: ${CPU_MAX_FREQ_IDLE} kHz (quiet mode)"
}

# --- State transitions ---
transition_to() {
  local new_state="$1"
  local now
  now=$(date +%s)
  local elapsed=$(( now - STATE_SINCE ))

  log "INFO" "State: $CURRENT_STATE -> $new_state (was in $CURRENT_STATE for ${elapsed}s)"
  CURRENT_STATE="$new_state"
  STATE_SINCE="$now"

  case "$new_state" in
    "$STATE_ACTIVE")
      set_performance_mode
      ;;
    "$STATE_IDLE")
      set_idle_mode
      ;;
  esac
}

# --- Status display ---
show_status() {
  local gpu_util power temp
  gpu_util=$(get_gpu_utilization)
  power=$(get_gpu_power)
  temp=$(get_gpu_temp)
  local now
  now=$(date +%s)
  local elapsed=$(( now - STATE_SINCE ))

  echo "=== Adaptive Power Status ==="
  echo "State:         $CURRENT_STATE (active for ${elapsed}s)"
  echo "Force mode:    ${FORCE_MODE:-automatic}"
  echo "GPU util:      ${gpu_util}% (general-activity fallback trigger at ${GENERAL_GPU_UTIL_THRESHOLD}%)"
  echo "GPU power:     ${power}W"
  echo "GPU temp:      ${temp}°C"
  echo "Config:"
  echo "  Cooldown:      ${COOLDOWN_TIME}s"
  echo "  Poll interval: ${GENERAL_POLL_INTERVAL}s"
  echo "==============================="
}

# --- Signal handling ---
cleanup() {
  log "INFO" "Received signal, shutting down..."
  if [[ "$CURRENT_STATE" != "$STATE_IDLE" ]]; then
    set_idle_mode
  fi
  exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

# --- Main loop: tail llm-server's log, react to real per-request tok/s ---
# The inner loop reads from a `docker logs -f` process substitution. If that
# underlying process dies (e.g. the container is `docker rm -f`'d and
# recreated, which happens routinely during manual restarts/testing), the
# pipe closes and `read` starts returning EOF *instantly* on every call
# instead of blocking for the timeout. Without detecting that, the loop spins
# at ~100% CPU on one core forever -- this was confirmed live (2026-07-22) to
# be the actual, sole cause of the "constant idle fan noise" that had been
# wrongly chased as a BIOS/EC hardware issue. `read -t` exit status is >128
# on a genuine timeout, 0 on a real line, and anything else (typically 1) is
# EOF -- the outer loop reconnects a fresh log stream when that happens.
main_loop() {
  log "INFO" "=== Adaptive Power Manager started (event-driven + general-GPU fallback) ==="
  log "INFO" "Configuration: cooldown=${COOLDOWN_TIME}s poll=${GENERAL_POLL_INTERVAL}s general_util_threshold=${GENERAL_GPU_UTIL_THRESHOLD}%"
  log "INFO" "Initial state: $CURRENT_STATE"

  local line rc

  while true; do
    while true; do
      if [[ "$FORCE_MODE" == "performance" ]]; then
        if [[ "$CURRENT_STATE" != "$STATE_ACTIVE" ]]; then
          transition_to "$STATE_ACTIVE"
        fi
        if read -r -t 5 line; then rc=0; else rc=$?; fi
        [[ "$rc" -eq 0 || "$rc" -gt 128 ]] && continue
        break
      elif [[ "$FORCE_MODE" == "idle" ]]; then
        if [[ "$CURRENT_STATE" != "$STATE_IDLE" ]]; then
          transition_to "$STATE_IDLE"
        fi
        if read -r -t 5 line; then rc=0; else rc=$?; fi
        [[ "$rc" -eq 0 || "$rc" -gt 128 ]] && continue
        break
      fi

      # Read timeout is GENERAL_POLL_INTERVAL, not COOLDOWN_TIME -- COOLDOWN_TIME
      # is now tracked separately via LAST_ACTIVITY_TS so a general-GPU-activity
      # check (below) can run every poll interval without waiting out the full
      # cooldown first.
      if IFS= read -r -t "$GENERAL_POLL_INTERVAL" line; then rc=0; else rc=$?; fi

      if [[ "$rc" -eq 0 ]]; then
        # Two signal lines from llama-server, either means "real generation is
        # happening right now":
        #   - "n_decoded = N, tg = X t/s, tg_3s = Y t/s" -- periodic heartbeat
        #     printed every ~3s DURING generation. Fires first, fast reaction.
        #   - "eval time = ... (X.XX tokens per second)" -- printed once at the
        #     END of a request. Only signal available for short generations
        #     (too brief for a tg_3s tick), but arrives late for long ones.
        # Must exclude "prompt eval time" (the PP line) which also contains
        # the substring "eval time".
        local tps=""
        if [[ "$line" == *"tg_3s ="* ]]; then
          [[ "$line" =~ tg_3s\ =\ *([0-9]+\.[0-9]+) ]] && tps="${BASH_REMATCH[1]}"
        elif [[ "$line" == *"eval time ="* && "$line" != *"prompt eval time"* ]]; then
          [[ "$line" =~ ([0-9]+\.[0-9]+)\ tokens\ per\ second\) ]] && tps="${BASH_REMATCH[1]}"
        fi
        if [[ -n "$tps" ]]; then
          log "INFO" "Generation event: ${tps} tok/s"
          LAST_ACTIVITY_TS=$(date +%s)
          if [[ "$CURRENT_STATE" == "$STATE_IDLE" ]]; then
            transition_to "$STATE_ACTIVE"
          fi
        fi
      elif [[ "$rc" -gt 128 ]]; then
        # Poll interval elapsed with no llm-server log line. That only means
        # llm-server is quiet -- it says nothing about the GPU as a whole, so
        # check general utilization before assuming idle is safe (this is the
        # fallback for "something else, not llm-server, is loading the GPU").
        local util
        util=$(get_gpu_utilization)
        if [[ -n "$util" && "$util" -ge "$GENERAL_GPU_UTIL_THRESHOLD" ]]; then
          log "INFO" "General GPU activity: ${util}% util (not from llm-server's log)"
          LAST_ACTIVITY_TS=$(date +%s)
          if [[ "$CURRENT_STATE" == "$STATE_IDLE" ]]; then
            transition_to "$STATE_ACTIVE"
          fi
        elif [[ "$CURRENT_STATE" == "$STATE_ACTIVE" ]]; then
          local now
          now=$(date +%s)
          if (( now - LAST_ACTIVITY_TS >= COOLDOWN_TIME )); then
            transition_to "$STATE_IDLE"
          fi
        fi
      else
        # EOF: the docker logs stream died. Break to the outer loop and
        # reconnect instead of spinning.
        break
      fi
    done < <(docker logs -f --tail 0 llm-server 2>&1)

    log "WARN" "Log stream ended (llm-server container restarted?) -- reconnecting in 3s"
    sleep 3
  done
}

# --- Parse arguments ---
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)
        show_status
        exit 0
        ;;
      --force-performance)
        FORCE_MODE="performance"
        log "INFO" "Force mode: performance"
        ;;
      --force-idle)
        FORCE_MODE="idle"
        log "INFO" "Force mode: idle"
        ;;
      --force-auto)
        FORCE_MODE=""
        log "INFO" "Force mode: automatic (disabled)"
        ;;
      --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --status              Show current state and configuration"
        echo "  --force-performance   Force performance mode"
        echo "  --force-idle          Force idle mode"
        echo "  --force-auto          Return to automatic mode"
        echo "  --help, -h            Show this help"
        echo ""
        echo "Without options, runs as a daemon, event-driven off llm-server's own log."
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        echo "Use --help for usage information" >&2
        exit 1
        ;;
    esac
    shift
  done
}

# --- Main ---
main() {
  parse_args "$@"

  # Root check (required for GPU/CPU control, but not for --status)
  if [[ $EUID -ne 0 ]]; then
    echo "Error: must run as root (sudo ./adaptive-power.sh)" >&2
    echo "  --status works without root" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  rotate_log

  if ! command -v nvidia-smi &>/dev/null; then
    echo "Error: nvidia-smi not found. Is NVIDIA driver installed?" >&2
    exit 1
  fi
  if ! command -v docker &>/dev/null; then
    echo "Error: docker not found." >&2
    exit 1
  fi

  # Assert persistence mode on every (re)start. Ubuntu's packaged
  # nvidia-persistenced.service runs with --no-persistence-mode by default --
  # the daemon being active does NOT mean persistence mode is actually on.
  # nvidia-smi -pm 1 is the real toggle and doesn't survive a reboot on its
  # own, so it must be reasserted here rather than relying on a one-shot
  # tune-system.sh run.
  if nvidia-smi -pm 1 2>/dev/null; then
    log "INFO" "Persistence mode: enabled"
  else
    log "WARN" "Persistence mode: failed to enable"
  fi

  if [[ -z "$FORCE_MODE" ]]; then
    log "INFO" "Starting in IDLE mode (quiet operation)"
    set_idle_mode
    CURRENT_STATE="$STATE_IDLE"
    STATE_SINCE=$(date +%s)
    LAST_ACTIVITY_TS="$STATE_SINCE"
  fi

  main_loop
}

main "$@"
