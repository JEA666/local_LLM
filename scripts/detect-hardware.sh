#!/usr/bin/env bash
set -euo pipefail

# One-shot hardware inventory for model selection -- see prompt.md. Prints
# GPU/CPU/RAM info in a fixed, parseable format so an AI assistant (or a
# human) can reason from real numbers instead of re-deriving detection
# commands from scratch every time this repo gets set up on new hardware.
# Also regenerates portal/docs/hardware.html from its .example template with
# the real values -- read-only against the system itself (queries only, no
# side effects there), but does write that one file.
#
# Usage: ./detect-hardware.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GPU_NAME="Not detected"
GPU_VRAM_TOTAL="n/a"
GPU_VRAM_FREE="n/a"
GPU_DRIVER="n/a"

echo "=== GPU ==="
if command -v nvidia-smi &>/dev/null; then
  IFS=',' read -r GPU_NAME GPU_VRAM_TOTAL GPU_VRAM_FREE GPU_DRIVER \
    < <(nvidia-smi --query-gpu=name,memory.total,memory.free,driver_version --format=csv,noheader)
  GPU_NAME="${GPU_NAME# }"
  GPU_VRAM_TOTAL="${GPU_VRAM_TOTAL# }"
  GPU_VRAM_FREE="${GPU_VRAM_FREE# }"
  GPU_DRIVER="${GPU_DRIVER# }"
  echo "Name:            $GPU_NAME"
  echo "VRAM total:      $GPU_VRAM_TOTAL"
  echo "VRAM free:       $GPU_VRAM_FREE"
  echo "Driver version:  $GPU_DRIVER"
else
  echo "nvidia-smi not found -- no NVIDIA GPU detected, or driver not installed."
  echo "This stack requires an NVIDIA GPU (see README.md 'Requirements')."
fi

echo
echo "=== Docker GPU support ==="
if docker info --format '{{.Runtimes}}' 2>/dev/null | grep -q nvidia; then
  TOOLKIT_STATUS="Registered"
  echo "nvidia-container-toolkit: registered"
else
  TOOLKIT_STATUS="NOT registered -- --gpus all will fail"
  echo "nvidia-container-toolkit: NOT registered -- --gpus all will fail."
  echo "See: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
fi

echo
echo "=== CPU ==="
CPU_CORES="$(nproc --all)"
CPU_MODEL="$(lscpu | grep "^Model name:" | sed 's/^Model name:[[:space:]]*//')"
echo "Cores (logical): $CPU_CORES"
lscpu | grep -E "^Model name|^Socket|^Core\(s\) per socket|^Thread\(s\) per core" || true

# Hybrid P-core/E-core topology (Intel 12th-gen+ desktop, most laptop chips).
# Exposed via sysfs on kernels that support it -- absent entirely on
# uniform-core CPUs (AMD, older Intel, most servers), not just empty.
CPU_TOPOLOGY="Uniform (no P-core/E-core split detected)"
if [[ -f /sys/devices/cpu_core/cpus && -f /sys/devices/cpu_atom/cpus ]]; then
  P_CORES="$(cat /sys/devices/cpu_core/cpus)"
  E_CORES="$(cat /sys/devices/cpu_atom/cpus)"
  CPU_TOPOLOGY="Hybrid -- P-cores: $P_CORES, E-cores: $E_CORES"
fi
echo "Topology: $CPU_TOPOLOGY"

echo
echo "=== RAM ==="
RAM_TOTAL="$(free -h | awk '/^Mem:/ {print $2}')"
free -h | awk 'NR==1 || NR==2'

echo
echo "=== Next step ==="
echo "Feed the numbers above into prompt.md's Step 2 (dense vs. MoE decision)."

DOCS_DIR="$SCRIPT_DIR/../portal/docs"
if [[ -f "$DOCS_DIR/hardware.html.example" ]]; then
  sed \
    -e "s/GPU_NAME_PLACEHOLDER/$GPU_NAME/g" \
    -e "s/GPU_VRAM_TOTAL_PLACEHOLDER/$GPU_VRAM_TOTAL/g" \
    -e "s/GPU_VRAM_FREE_PLACEHOLDER/$GPU_VRAM_FREE/g" \
    -e "s/GPU_DRIVER_PLACEHOLDER/$GPU_DRIVER/g" \
    -e "s/NVIDIA_TOOLKIT_STATUS_PLACEHOLDER/$TOOLKIT_STATUS/g" \
    -e "s/CPU_MODEL_PLACEHOLDER/$CPU_MODEL/g" \
    -e "s/CPU_CORES_PLACEHOLDER/$CPU_CORES/g" \
    -e "s/CPU_TOPOLOGY_PLACEHOLDER/$CPU_TOPOLOGY/g" \
    -e "s/RAM_TOTAL_PLACEHOLDER/$RAM_TOTAL/g" \
    -e "s/SCAN_DATE_PLACEHOLDER/$(date -Iseconds)/g" \
    "$DOCS_DIR/hardware.html.example" > "$DOCS_DIR/hardware.html"
  echo
  echo "portal/docs/hardware.html updated."
fi
