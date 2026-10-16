#!/usr/bin/env bash
# Prepare lab-gpu (RTX 3070 Ti, Ubuntu Server 26.04.1 LTS, kernel 7.0) BEFORE joining it to K3s: NVIDIA driver + container toolkit.
# K3s detects nvidia-container-runtime at start-up and adds the "nvidia" runtime to containerd
# plus a RuntimeClass named "nvidia". Safe to re-run.
# Usage: sudo ./gpu-node-prep.sh
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "run with sudo" >&2; exit 1; fi

# 1. Driver
if ! command -v nvidia-smi >/dev/null || ! nvidia-smi >/dev/null 2>&1; then
  echo "NVIDIA driver not working; installing the recommended server driver"
  if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -q enabled; then
    echo "NOTE: Secure Boot is ON. The driver's kernel module must be signed: during install you will"
    echo "      set a MOK password, then on the next reboot choose 'Enroll MOK' in the blue screen."
    echo "      (Or turn Secure Boot off in the BIOS for this lab machine.)"
  fi
  apt-get update
  # On 26.04.1 (2026-10-09) this picked nvidia-driver-595-open (595.99.02, CUDA 13.2) for an RTX 3070 Ti;
  # the open kernel modules are NVIDIA's recommendation for Turing and newer.
  ubuntu-drivers install
  echo "Reboot now, then re-run this script."
  exit 0
fi

# 2. NVIDIA Container Toolkit (repo setup per NVIDIA's install guide)
if ! command -v nvidia-container-runtime >/dev/null; then
  # NVIDIA's distro-agnostic "stable/deb" repo, per
  # https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
  # Works on 26.04.1 as a one-line .list with signed-by (installed toolkit 1.20.1 on 2026-10-09).
  curl -fsSL --proto '=https' https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL --proto '=https' https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update
  apt-get install -y nvidia-container-toolkit
fi

# 3. If k3s-agent is already installed, restart it so it re-detects the runtime.
if systemctl list-unit-files | grep -q '^k3s-agent'; then systemctl restart k3s-agent; fi

echo "--- verify"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
command -v nvidia-container-runtime
CFG=/var/lib/rancher/k3s/agent/etc/containerd/config.toml
if [[ -f $CFG ]]; then grep -n nvidia "$CFG" || echo "WARN: nvidia runtime not in $CFG yet"; fi
