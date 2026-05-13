#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
  ca-certificates \
  curl \
  dnsmasq \
  iproute2 \
  ipset \
  iptables \
  nftables \
  wireguard-tools

systemctl enable nftables >/dev/null 2>&1 || true

echo "Packages installed."
