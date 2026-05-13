#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${SPLITVPN_ENV:-/etc/splitvpn/splitvpn.env}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

need_cmd ip
need_cmd nft
need_cmd sysctl
need_cmd dnsmasq

"${BASE_DIR}/scripts/ensure-wireguard-configs.sh"
"${BASE_DIR}/scripts/render-configs.sh"
DNS_BACKEND="$(cat "$GENERATED_DIR/dns-set-backend")"

if [[ "$DNS_BACKEND" == "ipset" ]]; then
  need_cmd ipset
  need_cmd iptables
  IPSET_DOMAIN_SET="${IPSET_DOMAIN_SET:-splitvpn_ru_domain_v4}"
  IPSET_FORCE_RU_SET="${IPSET_FORCE_RU_SET:-splitvpn_force_ru_v4}"
  IPSET_FORCE_FI_SET="${IPSET_FORCE_FI_SET:-splitvpn_force_fi_v4}"
  ipset create "$IPSET_DOMAIN_SET" hash:ip family inet timeout 21600 -exist
  ipset create "$IPSET_FORCE_RU_SET" hash:ip family inet timeout 21600 -exist
  ipset create "$IPSET_FORCE_FI_SET" hash:ip family inet timeout 21600 -exist
fi

if [[ -x /etc/init.d/dnsmasq && "$DNSMASQ_CONF" == /etc/dnsmasq.d/* ]]; then
  /etc/init.d/dnsmasq checkconfig
else
  dnsmasq --test --conf-file="$DNSMASQ_CONF"
fi

for iface in "$WG_IN_IF" "$WG_OUT_IF" "$WAN_IF"; do
  if ! ip link show dev "$iface" >/dev/null 2>&1; then
    echo "Interface not found: $iface" >&2
    exit 1
  fi
done

if [[ -z "${WAN_GATEWAY:-}" ]]; then
  WAN_GATEWAY="$(ip -4 route show default dev "$WAN_IF" | awk '{print $3; exit}')"
fi

if [[ -z "${WAN_GATEWAY:-}" ]]; then
  echo "WAN_GATEWAY is empty and could not be detected for $WAN_IF." >&2
  exit 1
fi

for table_spec in "inet splitvpn" "ip splitvpn_nat" "ip splitvpn_dns"; do
  if nft list table $table_spec >/dev/null 2>&1; then
    nft delete table $table_spec
  fi
done

nft -c -f "$NFT_CONF"

ensure_rt_table() {
  local id="$1"
  local name="$2"

  if ! grep -Eq "^[[:space:]]*${id}[[:space:]]+${name}([[:space:]]|$)" /etc/iproute2/rt_tables; then
    sed -i "\|[[:space:]]${name}\$|d" /etc/iproute2/rt_tables
    printf '%s %s\n' "$id" "$name" >> /etc/iproute2/rt_tables
  fi
}

replace_rule() {
  local mark="$1"
  local table="$2"
  local priority="$3"

  while ip -4 rule del fwmark "$mark" table "$table" >/dev/null 2>&1; do :; done
  ip -4 rule add fwmark "$mark" table "$table" priority "$priority"
}

ensure_rt_table "$RU_TABLE_ID" "$RU_TABLE_NAME"
ensure_rt_table "$WG_TABLE_ID" "$WG_TABLE_NAME"

cat >/etc/sysctl.d/99-splitvpn.conf <<SYSCTL
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.${WG_IN_IF}.rp_filter=0
net.ipv4.conf.${WG_OUT_IF}.rp_filter=0
net.ipv4.conf.${WAN_IF}.rp_filter=0
SYSCTL

sysctl -p /etc/sysctl.d/99-splitvpn.conf >/dev/null

ip -4 route replace default via "$WAN_GATEWAY" dev "$WAN_IF" table "$RU_TABLE_NAME"

if [[ -n "${WG_GATEWAY:-}" ]]; then
  ip -4 route replace default via "$WG_GATEWAY" dev "$WG_OUT_IF" table "$WG_TABLE_NAME"
else
  ip -4 route replace default dev "$WG_OUT_IF" table "$WG_TABLE_NAME"
fi

replace_rule "$RU_MARK" "$RU_TABLE_NAME" "$RU_RULE_PRIORITY"
replace_rule "$WG_MARK" "$WG_TABLE_NAME" "$WG_RULE_PRIORITY"

if [[ "$DNS_BACKEND" == "ipset" ]]; then
  for rule in \
    "-i $WG_IN_IF -m set --match-set $IPSET_DOMAIN_SET dst -j MARK --set-mark $RU_MARK" \
    "-i $WG_IN_IF -m set --match-set $IPSET_FORCE_RU_SET dst -j MARK --set-mark $RU_MARK" \
    "-i $WG_IN_IF -m set --match-set $IPSET_FORCE_FI_SET dst -j MARK --set-mark $WG_MARK"; do
    while iptables -t mangle -D PREROUTING $rule >/dev/null 2>&1; do :; done
  done

  iptables -t mangle -A PREROUTING -i "$WG_IN_IF" -m set --match-set "$IPSET_DOMAIN_SET" dst -j MARK --set-mark "$RU_MARK"
  iptables -t mangle -A PREROUTING -i "$WG_IN_IF" -m set --match-set "$IPSET_FORCE_RU_SET" dst -j MARK --set-mark "$RU_MARK"
  iptables -t mangle -A PREROUTING -i "$WG_IN_IF" -m set --match-set "$IPSET_FORCE_FI_SET" dst -j MARK --set-mark "$WG_MARK"
fi

for upstream in $DNS_UPSTREAMS; do
  if [[ "$upstream" != *:* ]]; then
    ip -4 route replace "${upstream}/32" dev "$WG_OUT_IF" table main
  fi
done
nft -f "$NFT_CONF"
"${BASE_DIR}/scripts/update-manual-rules.sh"

if [[ -r "${GEOIP_NFT_CONF:-}" ]]; then
  nft -c -f "$GEOIP_NFT_CONF"
  nft -f "$GEOIP_NFT_CONF"
else
  echo "GeoIP nft file not found yet: ${GEOIP_NFT_CONF:-unset}"
  echo "Run: sudo ${BASE_DIR}/scripts/update-ru-geoip.sh"
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl restart dnsmasq
else
  service dnsmasq restart
fi

echo "splitvpn applied."
