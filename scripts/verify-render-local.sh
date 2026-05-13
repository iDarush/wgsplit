#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cp "$BASE_DIR/splitvpn.env.example" "$TMP_DIR/splitvpn.env"

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

test -s "$TMP_DIR/splitvpn.nft"
test -s "$TMP_DIR/splitvpn.conf"
grep -q 'table inet splitvpn' "$TMP_DIR/splitvpn.nft"
grep -q 'table ip splitvpn_nat' "$TMP_DIR/splitvpn.nft"
grep -q 'table ip splitvpn_dns' "$TMP_DIR/splitvpn.nft"
grep -q 'set force_ru_v4' "$TMP_DIR/splitvpn.nft"
grep -q 'set force_fi_v4' "$TMP_DIR/splitvpn.nft"
grep -q 'ipset=/ru/splitvpn_ru_domain_v4' "$TMP_DIR/splitvpn.conf"
grep -q 'server=1.1.1.1' "$TMP_DIR/splitvpn.conf"

echo "Render verification OK."
