#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${SPLITVPN_ENV:-/etc/splitvpn/splitvpn.env}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

if [[ ! -r "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

while ip -4 rule del fwmark "$RU_MARK" table "$RU_TABLE_NAME" >/dev/null 2>&1; do :; done
while ip -4 rule del fwmark "$WG_MARK" table "$WG_TABLE_NAME" >/dev/null 2>&1; do :; done

IPSET_DOMAIN_SET="${IPSET_DOMAIN_SET:-splitvpn_ru_domain_v4}"
IPSET_FORCE_RU_SET="${IPSET_FORCE_RU_SET:-splitvpn_force_ru_v4}"
IPSET_FORCE_FI_SET="${IPSET_FORCE_FI_SET:-splitvpn_force_fi_v4}"
if command -v iptables >/dev/null 2>&1; then
  for rule in \
    "-i $WG_IN_IF -m set --match-set $IPSET_DOMAIN_SET dst -j MARK --set-mark $RU_MARK" \
    "-i $WG_IN_IF -m set --match-set $IPSET_FORCE_RU_SET dst -j MARK --set-mark $RU_MARK" \
    "-i $WG_IN_IF -m set --match-set $IPSET_FORCE_FI_SET dst -j MARK --set-mark $WG_MARK"; do
    while iptables -t mangle -D PREROUTING $rule >/dev/null 2>&1; do :; done
  done
fi
if command -v ipset >/dev/null 2>&1; then
  ipset destroy "$IPSET_DOMAIN_SET" >/dev/null 2>&1 || true
  ipset destroy "$IPSET_FORCE_RU_SET" >/dev/null 2>&1 || true
  ipset destroy "$IPSET_FORCE_FI_SET" >/dev/null 2>&1 || true
fi

ip -4 route flush table "$RU_TABLE_NAME" || true
ip -4 route flush table "$WG_TABLE_NAME" || true

nft delete table inet splitvpn 2>/dev/null || true
nft delete table ip splitvpn_nat 2>/dev/null || true
nft delete table ip splitvpn_dns 2>/dev/null || true

if [[ "${1:-}" == "--purge" ]]; then
  rm -f "$DNSMASQ_CONF" /etc/sysctl.d/99-splitvpn.conf
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl restart dnsmasq 2>/dev/null || true
fi

echo "splitvpn runtime rules removed."
