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

command -v curl >/dev/null 2>&1 || {
  echo "Missing command: curl" >&2
  exit 1
}
command -v nft >/dev/null 2>&1 || {
  echo "Missing command: nft" >&2
  exit 1
}

mkdir -p "$GENERATED_DIR"

tmp_zone="$(mktemp)"
tmp_nft="$(mktemp)"
trap 'rm -f "$tmp_zone" "$tmp_nft"' EXIT

curl -fsSL "$RU_ZONE_URL" -o "$tmp_zone"

if ! nft list set inet splitvpn ru_geoip_v4 >/dev/null 2>&1; then
  echo "nft set inet splitvpn ru_geoip_v4 does not exist." >&2
  echo "Run apply.sh before update-ru-geoip.sh." >&2
  exit 1
fi

mapfile -t cidrs < <(
  grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' "$tmp_zone" | sort -u
)

if [[ "${#cidrs[@]}" -lt 100 ]]; then
  echo "Downloaded CIDR list looks too small: ${#cidrs[@]} entries." >&2
  exit 1
fi

{
  echo '#!/usr/sbin/nft -f'
  echo 'flush set inet splitvpn ru_geoip_v4'
  echo 'add element inet splitvpn ru_geoip_v4 {'
  for cidr in "${cidrs[@]}"; do
    echo "  $cidr,"
  done
  echo '}'
} > "$tmp_nft"

nft -c -f "$tmp_nft"
nft -f "$tmp_nft"
install -m 0644 "$tmp_nft" "$GEOIP_NFT_CONF"

echo "Loaded ${#cidrs[@]} RU IPv4 prefixes into ru_geoip_v4."
echo "Saved $GEOIP_NFT_CONF"

