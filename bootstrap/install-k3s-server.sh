#!/usr/bin/env bash
# Install the K3s server (control plane) on lab-cp (Ubuntu Server 26.04.1 LTS). Safe to re-run.
# Usage: sudo ./install-k3s-server.sh
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.34.6+k3s1}"   # reported working on Ubuntu Server 26.04.1 LTS (kernel 7.0)
NODE_NAME="${NODE_NAME:-lab-cp}"

if [[ $EUID -ne 0 ]]; then echo "run with sudo" >&2; exit 1; fi

if systemctl is-active --quiet k3s; then
  echo "k3s server already running; skipping install"
else
  # Download the installer first (TLS verified by curl) instead of piping straight into sh.
  curl -sfL --proto '=https' --tlsv1.2 -o /tmp/k3s-install.sh https://get.k3s.io
  INSTALL_K3S_VERSION="$K3S_VERSION" sh /tmp/k3s-install.sh server \
    --node-name "$NODE_NAME" \
    --write-kubeconfig-mode 0600 \
    --disable traefik            # no ingress needed; services are reached with kubectl port-forward
  rm -f /tmp/k3s-install.sh
fi

echo "--- verify"
# The node registers a few seconds after the service starts; wait for Ready before reporting.
for _ in $(seq 1 30); do
  k3s kubectl get node "$NODE_NAME" 2>/dev/null | grep -q " Ready" && break
  sleep 4
done
k3s kubectl get nodes -o wide
k3s kubectl get runtimeclass || true
echo
echo "Join token (copy it to lab-gpu over SSH, do not paste it into chat or git):"
echo "  /var/lib/rancher/k3s/server/node-token"
echo "Kubeconfig for Terraform: copy /etc/rancher/k3s/k3s.yaml to your workstation,"
echo "replace 127.0.0.1 with this node's LAN IP, and keep it out of the repo."
