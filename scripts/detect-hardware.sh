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
DIR="$SCRIPT_DIR/.."

# PSU and case can't be detected in software (no standard way for a consumer
# PSU to report its own wattage/model, and a case is never exposed to the OS
# at all) -- set once in .env instead, same pattern as DOMAIN/LLM_CPUSET.
ENV_FILE="$DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi
PSU_MODEL="${PSU_MODEL:-Not set -- see .env.example}"
CASE_MODEL="${CASE_MODEL:-Not set -- see .env.example}"

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
echo "=== Motherboard ==="
MOBO="Not detected"
if [[ -r /sys/class/dmi/id/board_vendor && -r /sys/class/dmi/id/board_name ]]; then
  MOBO="$(cat /sys/class/dmi/id/board_vendor) $(cat /sys/class/dmi/id/board_name)"
fi
echo "Board: $MOBO"

echo
echo "=== PSU / Case (from .env, not auto-detected) ==="
echo "PSU:  $PSU_MODEL"
echo "Case: $CASE_MODEL"

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
echo "Optional: sudo scripts/tune-system.sh applies OS-level tuning (governor,"
echo "sysctl, NVIDIA persistence mode) and can install the adaptive-power daemon"
echo "(quiet at idle, full power while llm-server -- or anything else -- is"
echo "using the GPU). See README.md 'Tuning'."

DOCS_DIR="$SCRIPT_DIR/../portal/docs"
if [[ -f "$DOCS_DIR/hardware.html.example" ]]; then
  # Plain string replacement (not sed) -- several of these values are
  # real-world free text (board names, PSU/case models from .env) that can
  # legitimately contain '/', '&', or '\', any of which breaks a sed
  # s/PLACEHOLDER/$VALUE/ substitution and, under this script's
  # `set -euo pipefail`, aborts the entire hardware scan over one field.
  # str.replace() has no delimiter or metacharacter to collide with.
  GPU_NAME="$GPU_NAME" GPU_VRAM_TOTAL="$GPU_VRAM_TOTAL" GPU_VRAM_FREE="$GPU_VRAM_FREE" \
  GPU_DRIVER="$GPU_DRIVER" TOOLKIT_STATUS="$TOOLKIT_STATUS" MOBO="$MOBO" \
  PSU_MODEL="$PSU_MODEL" CASE_MODEL="$CASE_MODEL" CPU_MODEL="$CPU_MODEL" \
  CPU_CORES="$CPU_CORES" CPU_TOPOLOGY="$CPU_TOPOLOGY" RAM_TOTAL="$RAM_TOTAL" \
  SCAN_DATE="$(date -Iseconds)" python3 -c "
import os

replacements = {
    'GPU_NAME_PLACEHOLDER': os.environ['GPU_NAME'],
    'GPU_VRAM_TOTAL_PLACEHOLDER': os.environ['GPU_VRAM_TOTAL'],
    'GPU_VRAM_FREE_PLACEHOLDER': os.environ['GPU_VRAM_FREE'],
    'GPU_DRIVER_PLACEHOLDER': os.environ['GPU_DRIVER'],
    'NVIDIA_TOOLKIT_STATUS_PLACEHOLDER': os.environ['TOOLKIT_STATUS'],
    'MOBO_PLACEHOLDER': os.environ['MOBO'],
    'PSU_PLACEHOLDER': os.environ['PSU_MODEL'],
    'CASE_PLACEHOLDER': os.environ['CASE_MODEL'],
    'CPU_MODEL_PLACEHOLDER': os.environ['CPU_MODEL'],
    'CPU_CORES_PLACEHOLDER': os.environ['CPU_CORES'],
    'CPU_TOPOLOGY_PLACEHOLDER': os.environ['CPU_TOPOLOGY'],
    'RAM_TOTAL_PLACEHOLDER': os.environ['RAM_TOTAL'],
    'SCAN_DATE_PLACEHOLDER': os.environ['SCAN_DATE'],
}

with open('$DOCS_DIR/hardware.html.example') as f:
    content = f.read()
for placeholder, value in replacements.items():
    content = content.replace(placeholder, value)
with open('$DOCS_DIR/hardware.html', 'w') as f:
    f.write(content)
"
  echo
  echo "portal/docs/hardware.html updated."
fi
