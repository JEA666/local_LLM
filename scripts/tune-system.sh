#!/usr/bin/env bash
set -euo pipefail

# tune-system.sh — OS tuning for LLM inference
# Run as root: sudo ./tune-system.sh
#
# Optional second step after detect-hardware.sh: that script tells you what
# hardware you have, this one tunes the OS around running an LLM on it.
# Nothing here is specific to any one GPU/CPU model -- it's generic Linux +
# NVIDIA host tuning. Machine-specific numbers (a GPU's actual safe power
# floor, a motherboard's fan-chip quirks) don't belong in a shared script;
# see "Deriving your own numbers" in README.md's Tuning section instead.
#
# What it does:
#   1. Fixes CPU governor (stops power-profiles-daemon, disables tuned)
#   2. Writes /etc/sysctl.d/99-llm-inference.conf (swappiness, mmap limits)
#   3. NVIDIA GPU: enables persistence mode
#   4. Transparent Huge Pages to madvise
#   5. Installs adaptive-power.service (optional -- auto-switches
#      performance/idle based on llm-server activity and general GPU load)
#
# Deliberately NOT included: static huge pages sized for model loading.
# That number is tied to one specific model's file size, and llm-server runs
# with --no-mmap (see deployments/compose.yml) -- the mmap-backed loading
# path static huge pages are meant to speed up isn't the one in use here, so
# reserving that memory generically would just lock it away for no benefit.
# If your own setup does rely on mmap'd loading, size vm.nr_hugepages
# yourself: (target memory in MB) / 2.

if [[ $EUID -ne 0 ]]; then
  echo "Error: must run as root (sudo ./tune-system.sh)" >&2
  exit 1
fi

echo "=== System Tuning for LLM Inference ==="
echo ""

# --- 1. Fix CPU governor (CRITICAL) ---
# power-profiles-daemon silently overrides CPU governor -- sysfs checks can
# show "performance" while actual throughput is well below what the governor
# setting implies. Must be masked, not just disabled: `systemctl disable`
# only removes the symlink, and some distros' systemd presets re-create it on
# boot via `preset-all`. `systemctl mask` blocks all starts, including that.
#
# tuned's throughput-performance profile is not used instead, because it
# forces max frequency even when idle -- unwanted heat/fan noise for no
# throughput benefit while nothing is running. adaptive-power.sh (below,
# optional) handles dynamic switching between performance and powersave.
echo "[1/5] Fixing CPU governor..."

# Mask unconditionally (idempotent, safe to re-run) rather than only when
# `is-enabled` prints exactly "enabled" -- some setups report "static"
# (pulled in indirectly, e.g. by a desktop session's D-Bus activation),
# which a strict string match would miss, letting the daemon come back later
# and fight for control of the governor.
if command -v power-profiles-daemon &>/dev/null || systemctl list-unit-files power-profiles-daemon.service &>/dev/null; then
  systemctl disable --now power-profiles-daemon 2>/dev/null || true
  systemctl mask power-profiles-daemon
  echo "  -> power-profiles-daemon masked (permanent, unconditional)."
else
  echo "  -> power-profiles-daemon not present, skipping."
fi

if systemctl list-unit-files tuned.service &>/dev/null; then
  if systemctl is-active --quiet tuned 2>/dev/null; then
    systemctl stop tuned
    echo "  -> tuned stopped."
  fi
  if systemctl is-enabled tuned 2>/dev/null | grep -q "enabled"; then
    systemctl disable tuned
    echo "  -> tuned disabled."
  fi
else
  echo "  -> tuned not present, skipping."
fi
echo "  -> CPU governor now stays under manual/adaptive-power.sh control, not overridden by a power daemon."

# --- 2. Sysctl tuning ---
echo "[2/5] Writing /etc/sysctl.d/99-llm-inference.conf..."
TIMESTAMP=$(date -Iseconds)
cat > /etc/sysctl.d/99-llm-inference.conf << EOF
# Kernel tuning for local LLM inference
# Applied by tune-system.sh on ${TIMESTAMP}

# Memory management -- prevent model weights / KV cache from being swapped
vm.swappiness = 10

# Raise mmap limit for large model files
vm.max_map_count = 1048576

# Allow overcommit for large mmap allocations
vm.overcommit_memory = 1
EOF
sysctl --system >/dev/null 2>&1
echo "  -> Done."

# --- 3. NVIDIA GPU: persistence mode ---
# Only persistence mode here -- GPU/VRAM clock locking and power limits are
# NOT set unconditionally by this script. Those are per-GPU numbers (see
# power-cap-sweep.sh) and belong in adaptive-power.conf, which the daemon
# below applies dynamically based on actual load.
echo "[3/5] NVIDIA GPU: persistence mode..."
if command -v nvidia-smi &>/dev/null; then
  # Persistence mode -- eliminates ~50-200ms GPU init latency per restart,
  # and nvidia-smi -pl settings hold more reliably with it on (see
  # power-cap-sweep.sh's own persistence-mode handling for the same reason).
  nvidia-smi -pm 1 2>/dev/null
  systemctl enable nvidia-persistenced 2>/dev/null || true
  systemctl start nvidia-persistenced 2>/dev/null || true
  echo "  -> Persistence mode: enabled"

  # Leave clocks unlocked -- adaptive-power.sh (if installed) manages that.
  nvidia-smi -rgc 2>/dev/null || true
  nvidia-smi -rac 2>/dev/null || true
  echo "  -> GPU/VRAM clocks: unlocked"
else
  echo "  -> Skipped (nvidia-smi not found)."
fi

# --- 4. Transparent Huge Pages ---
echo "[4/5] Setting Transparent Huge Pages to madvise..."
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
echo "  -> Done."

# --- 5. Install adaptive-power service (optional) ---
echo "[5/5] Installing adaptive-power service..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_FILE="${SCRIPT_DIR}/../init/adaptive-power.service"
CONF_FILE="${SCRIPT_DIR}/../configs/adaptive-power.conf"
if [[ ! -f "$CONF_FILE" ]]; then
  echo "  -> Skipped: configs/adaptive-power.conf not found."
  echo "     cp configs/adaptive-power.conf.example configs/adaptive-power.conf, edit it"
  echo "     (see README.md 'Tuning' for how to derive your own power-limit numbers via"
  echo "     power-cap-sweep.sh), then re-run this script."
elif [[ -f "${SCRIPT_DIR}/adaptive-power.sh" && -f "${SERVICE_FILE}" ]]; then
  chmod +x "${SCRIPT_DIR}/adaptive-power.sh"
  # ExecStart in the unit file is an absolute path -- systemd units can't
  # reference a relative/checkout-dependent location. sed it to this clone's
  # real location before installing, same reasoning as HOST_REPO_DIR in .env
  # for the admin panel (see README.md). Scoped to the ExecStart= line only
  # -- the placeholder also appears in the unit file's own explanatory
  # comment, which an unscoped substitution would mangle too.
  sed "/^ExecStart=/s|__ADAPTIVE_POWER_SH_PATH__|${SCRIPT_DIR}/adaptive-power.sh|" "$SERVICE_FILE" \
    > /etc/systemd/system/adaptive-power.service
  systemctl daemon-reload
  systemctl enable adaptive-power
  echo "  -> adaptive-power.service installed and enabled."
  echo "  -> Will auto-start on next boot. Start now: sudo systemctl start adaptive-power"
else
  echo "  -> WARNING: adaptive-power.sh or init/adaptive-power.service not found, skipping."
fi

echo ""
echo "=== All done. Reboot recommended. ==="
echo ""
echo "Changes applied:"
echo "  - power-profiles-daemon: masked if present (permanent)"
echo "  - tuned: disabled if present (was forcing performance mode even when idle)"
echo "  - vm.swappiness=10, vm.max_map_count=1048576, vm.overcommit_memory=1"
echo "  - NVIDIA persistence mode enabled; GPU/VRAM clocks left unlocked"
echo "  - THP: madvise"
echo "  - adaptive-power: installed if configs/adaptive-power.conf existed (see above)"
echo ""
echo "To check adaptive-power status: ./adaptive-power.sh --status"
