#!/usr/bin/env bash
# Tools for running this repo ON lab-cp (Ubuntu Server 26.04.1 LTS): Terraform from HashiCorp's apt repo,
# buildah to build the MCP image without a Docker daemon, a Python venv, jq, and a kubeconfig for the
# invoking user. Keeping these on lab-cp means the kubeconfig and secrets never leave the lab. Safe to re-run.
# Usage: sudo ./install-lab-tools.sh
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "run with sudo" >&2; exit 1; fi

# HashiCorp's Linux repository signing key, as published at https://www.hashicorp.com/en/trust/security
# (rotated 2026-09-10; the previous key 798A EC65 … A621 E701 is deprecated).
HASHICORP_FPR="D55C0D1AC78A8D8126CB631CFC9CA96ACA026560"
KEYRING=/usr/share/keyrings/hashicorp-archive-keyring.gpg

if [[ ! -f $KEYRING ]]; then
  curl -fsSL --proto '=https' --tlsv1.2 https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o "$KEYRING.tmp"
  if ! gpg --no-default-keyring --keyring "$KEYRING.tmp" --with-colons --fingerprint \
      | grep -q "^fpr:::::::::${HASHICORP_FPR}:"; then
    rm -f "$KEYRING.tmp"
    echo "HashiCorp signing key fingerprint does not match; refusing to add the repo" >&2
    exit 1
  fi
  mv "$KEYRING.tmp" "$KEYRING"
fi
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
echo "deb [signed-by=$KEYRING] https://apt.releases.hashicorp.com $CODENAME main" > /etc/apt/sources.list.d/hashicorp.list

apt-get update
apt-get install -y terraform buildah python3-venv jq

# kubeconfig for the user who ran sudo, so terraform/kubectl run without root.
if [[ -n ${SUDO_USER:-} && -f /etc/rancher/k3s/k3s.yaml ]]; then
  home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  install -d -m 700 -o "$SUDO_USER" -g "$SUDO_USER" "$home/.kube"
  install -m 600 -o "$SUDO_USER" -g "$SUDO_USER" /etc/rancher/k3s/k3s.yaml "$home/.kube/config"
fi

echo "--- verify"
terraform version | head -1
buildah --version
python3 --version
