#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPT_DIR="/opt/splitvpn"
ETC_DIR="/etc/splitvpn"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

install -d -m 0755 "$OPT_DIR" "$OPT_DIR/scripts" "$OPT_DIR/templates" "$ETC_DIR" "$ETC_DIR/generated"

install -m 0755 "$SRC_DIR"/scripts/*.sh "$OPT_DIR/scripts/"
install -m 0644 "$SRC_DIR"/templates/*.tmpl "$OPT_DIR/templates/"

if [[ ! -f "$ETC_DIR/splitvpn.env" ]]; then
  install -m 0600 "$SRC_DIR/splitvpn.env.example" "$ETC_DIR/splitvpn.env"
  echo "Created $ETC_DIR/splitvpn.env"
else
  echo "Keeping existing $ETC_DIR/splitvpn.env"
fi

for list_name in force-ru.txt force-fi.txt; do
  if [[ ! -f "$ETC_DIR/$list_name" ]]; then
    install -m 0644 /dev/null "$ETC_DIR/$list_name"
    {
      echo "# One domain, wildcard domain, IPv4 address, or IPv4 CIDR per line."
      echo "# Examples:"
      echo "# example.com"
      echo "# *.example.com"
      echo "# 203.0.113.10"
      echo "# 203.0.113.0/24"
    } > "$ETC_DIR/$list_name"
    echo "Created $ETC_DIR/$list_name"
  fi
done

if [[ -d /etc/systemd/system ]]; then
  install -m 0644 "$SRC_DIR"/systemd/*.service "$SRC_DIR"/systemd/*.timer /etc/systemd/system/
  systemctl daemon-reload
fi

echo "Installed to $OPT_DIR"
echo "Edit $ETC_DIR/splitvpn.env, then run:"
echo "  sudo $OPT_DIR/scripts/apply.sh"
echo "  sudo $OPT_DIR/scripts/update-ru-geoip.sh"
