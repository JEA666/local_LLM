#!/usr/bin/env bash
set -euo pipefail

# One-shot hardware inventory for model selection -- see prompt.md. Prints
# GPU/CPU/RAM info in a fixed, parseable format so an AI assistant (or a
# human) can reason from real numbers instead of re-deriving detection
# commands from scratch every time this repo gets set up on new hardware.
# Read-only: queries only, no side effects, safe to re-run anytime.
#
# Usage: ./detect-hardware.sh

echo "=== GPU ==="
if command -v nvidia-smi &>/dev/null; then
  nvidia-smi --query-gpu=name,memory.total,memory.free,driver_version --format=csv,noheader \
    | while IFS=',' read -r name mem_total mem_free driver; do
        echo "Name:            ${name# }"
        echo "VRAM total:      ${mem_total# }"
        echo "VRAM free:       ${mem_free# }"
        echo "Driver version:  ${driver# }"
      done
else
  echo "nvidia-smi not found -- no NVIDIA GPU detected, or driver not installed."
  echo "This stack requires an NVIDIA GPU (see README.md 'Requirements')."
fi

echo
echo "=== Docker GPU support ==="
if docker info --format '{{.Runtimes}}' 2>/dev/null | grep -q nvidia; then
  echo "nvidia-container-toolkit: registered"
else
  echo "nvidia-container-toolkit: NOT registered -- --gpus all will fail."
  echo "See: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
fi

echo
echo "=== CPU ==="
echo "Cores (logical): $(nproc --all)"
lscpu | grep -E "^Model name|^Socket|^Core\(s\) per socket|^Thread\(s\) per core" || true

echo
echo "=== RAM ==="
free -h | awk 'NR==1 || NR==2'

echo
echo "=== Next step ==="
echo "Feed the numbers above into prompt.md's Step 2 (dense vs. MoE decision)."
