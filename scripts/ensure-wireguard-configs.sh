#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${SPLITVPN_ENV:-/etc/splitvpn/splitvpn.env}"

if [[ ! -r "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

WIREGUARD_DIR="${WIREGUARD_DIR:-/etc/wireguard}"
WG0_CONF="${WIREGUARD_DIR}/${WG_OUT_IF:-wg0}.conf"
WG1_CONF="${WIREGUARD_DIR}/${WG_IN_IF:-wg1}.conf"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Required variable is empty: $name" >&2
    exit 1
  fi
}

install_config() {
  local tmp="$1"
  local dest="$2"

  install -d -m 0700 "$(dirname "$dest")"
  install -m 0600 "$tmp" "$dest"
}

print_public_key() {
  local label="$1"
  local private_key="$2"

  if command -v wg >/dev/null 2>&1; then
    printf '%s_public_key=%s\n' "$label" "$(printf '%s\n' "$private_key" | wg pubkey)"
  fi
}

create_wg0() {
  if [[ -e "$WG0_CONF" ]]; then
    echo "Keeping existing $WG0_CONF"
    return
  fi

  require_var WG0_ADDRESS
  require_var WG0_PRIVATE_KEY
  require_var WG0_PEER_PUBLIC_KEY
  require_var WG0_ENDPOINT
  require_var WG0_ALLOWED_IPS

  local tmp
  tmp="$(mktemp)"

  {
    echo "[Interface]"
    echo "Address = $WG0_ADDRESS"
    echo "PrivateKey = $WG0_PRIVATE_KEY"
    if [[ -n "${WG0_MTU:-}" ]]; then
      echo "MTU = $WG0_MTU"
    fi
    if [[ -n "${WG0_TABLE:-off}" ]]; then
      echo "Table = ${WG0_TABLE:-off}"
    fi
    echo
    echo "[Peer]"
    echo "PublicKey = $WG0_PEER_PUBLIC_KEY"
    echo "AllowedIPs = $WG0_ALLOWED_IPS"
    echo "Endpoint = $WG0_ENDPOINT"
    if [[ -n "${WG0_PERSISTENT_KEEPALIVE:-25}" ]]; then
      echo "PersistentKeepalive = ${WG0_PERSISTENT_KEEPALIVE:-25}"
    fi
  } > "$tmp"

  install_config "$tmp" "$WG0_CONF"
  rm -f "$tmp"
  echo "Created $WG0_CONF"
  print_public_key "${WG_OUT_IF:-wg0}" "$WG0_PRIVATE_KEY"
}

create_wg1() {
  if [[ -e "$WG1_CONF" ]]; then
    echo "Keeping existing $WG1_CONF"
    return
  fi

  require_var WG1_ADDRESS
  require_var WG1_LISTEN_PORT

  local private_key="${WG1_PRIVATE_KEY:-}"
  if [[ -z "$private_key" ]]; then
    need_cmd wg
    private_key="$(wg genkey)"
  fi

  local tmp
  tmp="$(mktemp)"

  {
    echo "[Interface]"
    echo "Address = $WG1_ADDRESS"
    echo "PrivateKey = $private_key"
    echo "ListenPort = $WG1_LISTEN_PORT"
    if [[ -n "${WG1_MTU:-}" ]]; then
      echo "MTU = $WG1_MTU"
    fi
  } > "$tmp"

  install_config "$tmp" "$WG1_CONF"
  rm -f "$tmp"
  echo "Created $WG1_CONF"
  print_public_key "${WG_IN_IF:-wg1}" "$private_key"
}

create_wg0
create_wg1
