#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/wireguard"

cat > "$TMP_DIR/bin/wg" <<'WG'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  genkey)
    echo "WG1_GENERATED_PRIVATE_KEY"
    ;;
  pubkey)
    key="$(cat)"
    if [[ "$key" == "WG1_GENERATED_PRIVATE_KEY" ]]; then
      echo "WG1_GENERATED_PUBLIC_KEY"
    else
      echo "PUBKEY_FOR_${key}"
    fi
    ;;
  *)
    echo "unexpected wg command: $*" >&2
    exit 1
    ;;
esac
WG
chmod +x "$TMP_DIR/bin/wg"

cp "$BASE_DIR/splitvpn.env.example" "$TMP_DIR/splitvpn.env"

cat >> "$TMP_DIR/splitvpn.env" <<ENV
WIREGUARD_DIR="$TMP_DIR/wireguard"
WG0_ADDRESS="10.30.0.3/32"
WG0_PRIVATE_KEY="WG0_PRIVATE_KEY"
WG0_PEER_PUBLIC_KEY="FI_PUBLIC_KEY"
WG0_ENDPOINT="116.202.97.35:51820"
WG0_ALLOWED_IPS="0.0.0.0/0"
WG0_TABLE="off"
WG0_MTU="1420"
WG0_PERSISTENT_KEEPALIVE="25"
WG1_ADDRESS="10.40.0.1/24"
WG1_LISTEN_PORT="51821"
WG1_MTU="1420"
WG1_PRIVATE_KEY=""
ENV

PATH="$TMP_DIR/bin:$PATH" SPLITVPN_ENV="$TMP_DIR/splitvpn.env" "$BASE_DIR/scripts/ensure-wireguard-configs.sh" >/dev/null

test -s "$TMP_DIR/wireguard/wg0.conf"
test -s "$TMP_DIR/wireguard/wg1.conf"

grep -q '^Address = 10.30.0.3/32$' "$TMP_DIR/wireguard/wg0.conf"
grep -q '^PrivateKey = WG0_PRIVATE_KEY$' "$TMP_DIR/wireguard/wg0.conf"
grep -q '^PublicKey = FI_PUBLIC_KEY$' "$TMP_DIR/wireguard/wg0.conf"
grep -q '^Endpoint = 116.202.97.35:51820$' "$TMP_DIR/wireguard/wg0.conf"
grep -q '^AllowedIPs = 0.0.0.0/0$' "$TMP_DIR/wireguard/wg0.conf"
grep -q '^Table = off$' "$TMP_DIR/wireguard/wg0.conf"

grep -q '^Address = 10.40.0.1/24$' "$TMP_DIR/wireguard/wg1.conf"
grep -q '^PrivateKey = WG1_GENERATED_PRIVATE_KEY$' "$TMP_DIR/wireguard/wg1.conf"
grep -q '^ListenPort = 51821$' "$TMP_DIR/wireguard/wg1.conf"
grep -q '^MTU = 1420$' "$TMP_DIR/wireguard/wg1.conf"

wg1_before="$(sha256sum "$TMP_DIR/wireguard/wg1.conf")"
PATH="$TMP_DIR/bin:$PATH" SPLITVPN_ENV="$TMP_DIR/splitvpn.env" "$BASE_DIR/scripts/ensure-wireguard-configs.sh" >/dev/null
wg1_after="$(sha256sum "$TMP_DIR/wireguard/wg1.conf")"
test "$wg1_before" = "$wg1_after"

mode="$(stat -c '%a' "$TMP_DIR/wireguard/wg1.conf")"
test "$mode" = "600"

echo "WireGuard bootstrap verification OK."
