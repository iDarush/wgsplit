#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${SPLITVPN_ENV:-/etc/splitvpn/splitvpn.env}"
DRY_RUN="0"

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN="1"
fi

if [[ "$DRY_RUN" != "1" && "${EUID}" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

if [[ ! -r "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

ETC_DIR="${ETC_DIR:-/etc/splitvpn}"
GENERATED_DIR="${GENERATED_DIR:-/etc/splitvpn/generated}"
MANUAL_NFT_CONF="${MANUAL_NFT_CONF:-$GENERATED_DIR/manual-rules.nft}"
FORCE_RU_FILE="${FORCE_RU_FILE:-$ETC_DIR/force-ru.txt}"
FORCE_FI_FILE="${FORCE_FI_FILE:-$ETC_DIR/force-fi.txt}"
IPSET_FORCE_RU_SET="${IPSET_FORCE_RU_SET:-splitvpn_force_ru_v4}"
IPSET_FORCE_FI_SET="${IPSET_FORCE_FI_SET:-splitvpn_force_fi_v4}"

mkdir -p "$GENERATED_DIR"

is_ipv4_or_cidr() {
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]
}

read_manual_ips() {
  local file="$1"
  local raw item

  [[ -r "$file" ]] || return 0
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    item="${raw%%#*}"
    item="$(printf '%s' "$item" | tr -d '\r' | xargs)"
    [[ -n "$item" ]] || continue
    is_ipv4_or_cidr "$item" || continue
    printf '%s\n' "$item"
  done < "$file" | sort -u
}

emit_add_element() {
  local set_name="$1"
  shift
  local values=("$@")

  [[ "${#values[@]}" -gt 0 ]] || return 0
  echo "add element inet splitvpn $set_name {"
  local value
  for value in "${values[@]}"; do
    echo "  $value,"
  done
  echo "}"
}

mapfile -t force_ru_ips < <(read_manual_ips "$FORCE_RU_FILE")
mapfile -t force_fi_ips < <(read_manual_ips "$FORCE_FI_FILE")

{
  echo '#!/usr/sbin/nft -f'
  echo 'flush set inet splitvpn force_ru_v4'
  echo 'flush set inet splitvpn force_fi_v4'
  emit_add_element force_ru_v4 "${force_ru_ips[@]}"
  emit_add_element force_fi_v4 "${force_fi_ips[@]}"
} > "$MANUAL_NFT_CONF"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Rendered $MANUAL_NFT_CONF"
  exit 0
fi

nft -c -f "$MANUAL_NFT_CONF"
nft -f "$MANUAL_NFT_CONF"

if command -v ipset >/dev/null 2>&1; then
  ipset create "$IPSET_FORCE_RU_SET" hash:ip family inet timeout 21600 -exist
  ipset create "$IPSET_FORCE_FI_SET" hash:ip family inet timeout 21600 -exist
  ipset flush "$IPSET_FORCE_RU_SET"
  ipset flush "$IPSET_FORCE_FI_SET"
fi

echo "Loaded manual rules: force_ru=${#force_ru_ips[@]} IPv4 entries, force_fi=${#force_fi_ips[@]} IPv4 entries."

