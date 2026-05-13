#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${SPLITVPN_ENV:-/etc/splitvpn/splitvpn.env}"

if [[ "${1:-}" == "" || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0 <domain>"
  exit 1
fi

if [[ ! -r "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

domain="$1"
domain="${domain#http://}"
domain="${domain#https://}"
domain="${domain%%/*}"
domain="${domain%.}"

ETC_DIR="${ETC_DIR:-/etc/splitvpn}"
FORCE_RU_FILE="${FORCE_RU_FILE:-$ETC_DIR/force-ru.txt}"
FORCE_FI_FILE="${FORCE_FI_FILE:-$ETC_DIR/force-fi.txt}"
GEOIP_NFT_CONF="${GEOIP_NFT_CONF:-/etc/splitvpn/generated/ru-geoip-v4.nft}"
DNS_LISTEN_ADDRESS="${DNS_LISTEN_ADDRESS:-127.0.0.1}"
RU_MARK="${RU_MARK:-0x10}"
WG_MARK="${WG_MARK:-0x20}"
WAN_IF="${WAN_IF:-}"
WG_OUT_IF="${WG_OUT_IF:-}"

resolve_a_records() {
  local name="$1"

  if command -v dig >/dev/null 2>&1; then
    dig +short A "@$DNS_LISTEN_ADDRESS" "$name" | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u
    return
  fi

  if command -v nslookup >/dev/null 2>&1; then
    nslookup -type=A "$name" "$DNS_LISTEN_ADDRESS" 2>/dev/null |
      awk '/^Address: / {print $2}' |
      grep -E '^[0-9]+(\.[0-9]+){3}$' |
      sort -u
    return
  fi

  getent ahostsv4 "$name" | awk '{print $1}' | sort -u
}

public_ip_for_interface() {
  local iface="$1"

  [[ -n "$iface" ]] || {
    echo "unavailable"
    return
  }

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl-not-installed"
    return
  fi

  curl -4 -fsS --max-time 6 --interface "$iface" https://api.ipify.org 2>/dev/null ||
    curl -4 -fsS --max-time 6 --interface "$iface" https://ifconfig.me/ip 2>/dev/null ||
    echo "unavailable"
}

mapfile -t resolved_ips < <(resolve_a_records "$domain")

echo "domain: $domain"
echo "resolver: $DNS_LISTEN_ADDRESS"
echo

if [[ "${#resolved_ips[@]}" -eq 0 ]]; then
  echo "resolved IPv4: none"
else
  echo "resolved IPv4:"
  printf '  %s\n' "${resolved_ips[@]}"
fi

echo
echo "control public IPs:"
echo "  local ($WAN_IF): $(public_ip_for_interface "$WAN_IF")"
echo "  FI ($WG_OUT_IF): $(public_ip_for_interface "$WG_OUT_IF")"
echo

if [[ "${#resolved_ips[@]}" -eq 0 ]]; then
  exit 2
fi

python3 - "$domain" "$FORCE_RU_FILE" "$FORCE_FI_FILE" "$GEOIP_NFT_CONF" "$RU_MARK" "$WG_MARK" "${resolved_ips[@]}" <<'PY'
import ipaddress
import re
import subprocess
import sys
from pathlib import Path

domain = sys.argv[1].lower().rstrip(".")
force_ru_file = Path(sys.argv[2])
force_fi_file = Path(sys.argv[3])
geoip_file = Path(sys.argv[4])
ru_mark = sys.argv[5]
wg_mark = sys.argv[6]
ips = sys.argv[7:]


def clean_lines(path):
    if not path.exists():
        return []
    lines = []
    for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        item = raw.split("#", 1)[0].strip().lower().rstrip(".")
        if item:
            lines.append(item)
    return lines


def split_entries(lines):
    domains = []
    networks = []
    for item in lines:
        try:
            if "/" in item:
                networks.append(ipaddress.ip_network(item, strict=False))
            else:
                networks.append(ipaddress.ip_network(item + "/32", strict=False))
            continue
        except ValueError:
            pass

        if item.startswith("*."):
            item = item[2:]
        domains.append(item)
    return domains, networks


def domain_matches(entries):
    return any(domain == entry or domain.endswith("." + entry) for entry in entries)


def load_geoip(path):
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8", errors="ignore")
    found = re.findall(r"\b(?:\d{1,3}\.){3}\d{1,3}/\d{1,2}\b|\b(?:\d{1,3}\.){3}\d{1,3}\b", text)
    networks = []
    for item in found:
        try:
            if "/" in item:
                networks.append(ipaddress.ip_network(item, strict=False))
            else:
                networks.append(ipaddress.ip_network(item + "/32", strict=False))
        except ValueError:
            continue
    return networks


def in_any(ip, networks):
    return any(ip in net for net in networks)


force_ru_domains, force_ru_nets = split_entries(clean_lines(force_ru_file))
force_fi_domains, force_fi_nets = split_entries(clean_lines(force_fi_file))
geoip_nets = load_geoip(geoip_file)

force_fi_domain = domain_matches(force_fi_domains)
force_ru_domain = domain_matches(force_ru_domains)
ru_zone_domain = domain.endswith(".ru") or domain == "ru"

print("decision per IP:")
for raw_ip in ips:
    ip = ipaddress.ip_address(raw_ip)

    if force_fi_domain or in_any(ip, force_fi_nets):
        reason = "force-fi"
        mark = wg_mark
        egress = "FI / wg0"
    elif force_ru_domain or in_any(ip, force_ru_nets):
        reason = "force-ru"
        mark = ru_mark
        egress = "local / WAN"
    elif ru_zone_domain:
        reason = ".ru-domain"
        mark = ru_mark
        egress = "local / WAN"
    elif in_any(ip, geoip_nets):
        reason = "ru-geoip"
        mark = ru_mark
        egress = "local / WAN"
    else:
        reason = "default-fi"
        mark = wg_mark
        egress = "FI / wg0"

    route = subprocess.run(
        ["ip", "-4", "route", "get", raw_ip, "mark", mark],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    ).stdout.strip().splitlines()
    route_line = route[0] if route else "route unavailable"
    print(f"  {raw_ip}: {egress} ({reason}, mark {mark})")
    print(f"    route: {route_line}")
PY

