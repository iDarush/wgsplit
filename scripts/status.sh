#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${SPLITVPN_ENV:-/etc/splitvpn/splitvpn.env}"

if [[ ! -r "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

echo "== ip rules =="
ip -4 rule show | grep -E "fwmark (${RU_MARK}|${WG_MARK})|${RU_TABLE_NAME}|${WG_TABLE_NAME}" || true

echo
echo "== routes: $RU_TABLE_NAME =="
ip -4 route show table "$RU_TABLE_NAME" || true

echo
echo "== routes: $WG_TABLE_NAME =="
ip -4 route show table "$WG_TABLE_NAME" || true

echo
echo "== nft tables =="
nft list table inet splitvpn 2>/dev/null | sed -n '1,120p' || true

echo
echo "== set sizes =="
for set_name in ru_domain_v4 ru_geoip_v4 force_ru_v4 force_fi_v4; do
  count="$(nft list set inet splitvpn "$set_name" 2>/dev/null | grep -Ec '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)"
  echo "$set_name: $count IPv4 entries shown by nft output"
done

if command -v ipset >/dev/null 2>&1; then
  echo
  echo "== ipset sizes =="
  for set_name in "${IPSET_DOMAIN_SET:-splitvpn_ru_domain_v4}" "${IPSET_FORCE_RU_SET:-splitvpn_force_ru_v4}" "${IPSET_FORCE_FI_SET:-splitvpn_force_fi_v4}"; do
    count="$(ipset list "$set_name" 2>/dev/null | awk -F': ' '/Number of entries/ {print $2; exit}')"
    echo "$set_name: ${count:-missing}"
  done
fi

echo
echo "== dnsmasq =="
if command -v systemctl >/dev/null 2>&1; then
  systemctl --no-pager --full status dnsmasq | sed -n '1,20p' || true
else
  service dnsmasq status || true
fi
