#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <client-name> <client-ip-cidr> [endpoint]" >&2
  echo "Example: $0 darush_iphone_split 10.40.0.3/32 194.113.35.230:51821" >&2
}

if [[ "${1:-}" == "" || "${2:-}" == "" ]]; then
  usage
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

name="$1"
client_ip="$2"
endpoint="${3:-}"
wg_if="${WG_IN_IF:-wg1}"
wg_conf="/etc/wireguard/${wg_if}.conf"
client_dir="/etc/wireguard/clients"
conf="${client_dir}/${name}.conf"
qr="${client_dir}/${name}.png"

if [[ ! "$name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid client name: $name" >&2
  exit 1
fi

if [[ ! "$client_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
  echo "Invalid client IPv4 CIDR: $client_ip" >&2
  exit 1
fi

if [[ ! -r "$wg_conf" ]]; then
  echo "Missing WireGuard config: $wg_conf" >&2
  exit 1
fi

if [[ -z "$endpoint" ]]; then
  listen_port="$(awk -F= '/^[[:space:]]*ListenPort[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$wg_conf")"
  public_ip="$(curl -4 -fsS --max-time 6 --interface "${WAN_IF:-}" https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 6 https://api.ipify.org)"
  endpoint="${public_ip}:${listen_port}"
fi

command -v wg >/dev/null 2>&1 || {
  echo "Missing command: wg" >&2
  exit 1
}
command -v qrencode >/dev/null 2>&1 || {
  echo "Missing command: qrencode" >&2
  exit 1
}

install -d -m 700 -o root -g root "$client_dir"

if [[ -e "$conf" ]]; then
  echo "Client config already exists: $conf" >&2
  exit 2
fi

if grep -q "AllowedIPs[[:space:]]*=[[:space:]]*${client_ip//\//\\/}" "$wg_conf"; then
  echo "Client IP already exists in $wg_conf: $client_ip" >&2
  exit 3
fi

server_pub="$(wg show "$wg_if" public-key)"
client_private="$(wg genkey)"
client_public="$(printf '%s\n' "$client_private" | wg pubkey)"

tmp_conf="$(mktemp)"
trap 'rm -f "$tmp_conf"' EXIT

cat > "$tmp_conf" <<CLIENT
[Interface]
PrivateKey = $client_private
Address = $client_ip
DNS = 10.40.0.1
MTU = 1420

[Peer]
PublicKey = $server_pub
AllowedIPs = 0.0.0.0/0
Endpoint = $endpoint
PersistentKeepalive = 25
CLIENT

install -m 600 -o root -g root "$tmp_conf" "$conf"
cp "$wg_conf" "${wg_conf}.bak.$(date +%Y%m%d-%H%M%S)"

{
  printf '\n# %s\n' "$name"
  printf '[Peer]\n'
  printf 'PublicKey = %s\n' "$client_public"
  printf 'AllowedIPs = %s\n' "$client_ip"
} >> "$wg_conf"

wg set "$wg_if" peer "$client_public" allowed-ips "$client_ip"
ip -4 route replace "$client_ip" dev "$wg_if"
qrencode -o "$qr" -t PNG -s 8 -m 2 < "$conf"
chmod 600 "$qr"

echo "client_name=$name"
echo "client_ip=$client_ip"
echo "client_public_key=$client_public"
echo "client_config=$conf"
echo "client_qr=$qr"
