#!/usr/bin/env bash
# Join lab-gpu (Ubuntu Server 26.04.1 LTS) to the cluster as a K3s agent, labelled and tainted so only GPU workloads land here.
# Run gpu-node-prep.sh first. Safe to re-run.
# Usage: sudo ./install-k3s-agent.sh https://<lab-cp-ip>:6443 /root/k3s-node-token
set -euo pipefail

SERVER_URL="${1:?server URL, e.g. https://192.168.1.10:6443}"
TOKEN_FILE="${2:?path to a file holding the node token (chmod 600)}"
K3S_VERSION="${K3S_VERSION:-v1.34.6+k3s1}"   # must match the server's version
NODE_NAME="${NODE_NAME:-lab-gpu}"

if [[ $EUID -ne 0 ]]; then echo "run with sudo" >&2; exit 1; fi
if [[ ! -s $TOKEN_FILE ]]; then echo "token file $TOKEN_FILE missing or empty" >&2; exit 1; fi
chmod 600 "$TOKEN_FILE"

if systemctl is-active --quiet k3s-agent; then
  echo "k3s agent already running; skipping install"
else
  curl -sfL --proto '=https' --tlsv1.2 -o /tmp/k3s-install.sh https://get.k3s.io
  K3S_URL="$SERVER_URL" K3S_TOKEN_FILE="$TOKEN_FILE" INSTALL_K3S_VERSION="$K3S_VERSION" \
    sh /tmp/k3s-install.sh agent \
      --node-name "$NODE_NAME" \
      --node-label gpu=true \
      --node-label nvidia.com/gpu.present=true \
      --node-taint nvidia.com/gpu=present:NoSchedule
  rm -f /tmp/k3s-install.sh
fi

echo "--- verify (agent side)"
systemctl is-active k3s-agent
grep -n nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml \
  || echo "WARN: nvidia runtime not detected; re-run gpu-node-prep.sh"
echo "On lab-cp run:  k3s kubectl get node $NODE_NAME --show-labels  and check the taint with"
echo "               k3s kubectl describe node $NODE_NAME | grep Taints"
