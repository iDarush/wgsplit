#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cp "$BASE_DIR/splitvpn.env.example" "$TMP_DIR/splitvpn.env"

cat > "$TMP_DIR/force-ru.txt" <<'LIST'
# route these through the local WAN interface
ya.ru
*.gosuslugi.ru
5.255.255.5
77.88.0.0/16
LIST

cat > "$TMP_DIR/force-fi.txt" <<'LIST'
# route these through FI even if GeoIP says RU
example.com
*.blocked.example
5.255.255.5
203.0.113.0/24
LIST

sed -i \
  -e 's#DNS_SET_BACKEND="auto"#DNS_SET_BACKEND="ipset"#' \
  -e "s#NFT_CONF=\"/etc/splitvpn/generated/splitvpn.nft\"#NFT_CONF=\"$TMP_DIR/splitvpn.nft\"#" \
  -e "s#DNSMASQ_CONF=\"/etc/dnsmasq.d/splitvpn.conf\"#DNSMASQ_CONF=\"$TMP_DIR/splitvpn.conf\"#" \
  -e "s#GENERATED_DIR=\"/etc/splitvpn/generated\"#GENERATED_DIR=\"$TMP_DIR\"#" \
  -e "s#GEOIP_NFT_CONF=\"/etc/splitvpn/generated/ru-geoip-v4.nft\"#GEOIP_NFT_CONF=\"$TMP_DIR/ru-geoip-v4.nft\"#" \
  -e "s#MANUAL_NFT_CONF=\"/etc/splitvpn/generated/manual-rules.nft\"#MANUAL_NFT_CONF=\"$TMP_DIR/manual-rules.nft\"#" \
  -e "s#ETC_DIR=\"/etc/splitvpn\"#ETC_DIR=\"$TMP_DIR\"#" \
  -e "s#FORCE_RU_FILE=\"/etc/splitvpn/force-ru.txt\"#FORCE_RU_FILE=\"$TMP_DIR/force-ru.txt\"#" \
  -e "s#FORCE_FI_FILE=\"/etc/splitvpn/force-fi.txt\"#FORCE_FI_FILE=\"$TMP_DIR/force-fi.txt\"#" \
  "$TMP_DIR/splitvpn.env"

SPLITVPN_ENV="$TMP_DIR/splitvpn.env" "$BASE_DIR/scripts/render-configs.sh" >/dev/null
SPLITVPN_ENV="$TMP_DIR/splitvpn.env" "$BASE_DIR/scripts/update-manual-rules.sh" --dry-run >/dev/null

grep -q 'set force_ru_v4' "$TMP_DIR/splitvpn.nft"
grep -q 'set force_fi_v4' "$TMP_DIR/splitvpn.nft"
grep -q 'ip daddr @force_fi_v4 meta mark set __WG_MARK__' "$BASE_DIR/templates/splitvpn.nft.tmpl"
grep -q 'ipset=/ya.ru/splitvpn_force_ru_v4' "$TMP_DIR/splitvpn.conf"
grep -q 'ipset=/example.com/splitvpn_force_fi_v4' "$TMP_DIR/splitvpn.conf"
grep -q 'add element inet splitvpn force_ru_v4' "$TMP_DIR/manual-rules.nft"
grep -q '77.88.0.0/16' "$TMP_DIR/manual-rules.nft"
grep -q 'add element inet splitvpn force_fi_v4' "$TMP_DIR/manual-rules.nft"
grep -q '203.0.113.0/24' "$TMP_DIR/manual-rules.nft"

echo "Manual rule verification OK."
