# WireGuard RU split routing

This package configures a RU VPS that accepts clients on `wg1`, sends most
forwarded traffic to an upstream WireGuard tunnel on `wg0`, and sends traffic
classified as RU to the public interface `dev0`.

The classification has two sources:

- DNS answers for `.ru` domains resolved by local `dnsmasq`.
- RU IPv4 prefixes downloaded into an `nftables` set.

DNS upstream traffic is pinned to `wg0` so the VPS provider DNS path on `dev0`
cannot poison answers used for routing decisions.

## Files

- `splitvpn.env.example` - copy to `/etc/splitvpn/splitvpn.env` and edit.
- `templates/splitvpn.nft.tmpl` - nftables template.
- `scripts/install.sh` - copies files to `/opt/splitvpn` and `/etc/splitvpn`.
- `scripts/install-packages-ubuntu.sh` - installs Ubuntu package dependencies.
- `scripts/ensure-wireguard-configs.sh` - creates missing `wg0.conf`/`wg1.conf` from env.
- `scripts/apply.sh` - renders configs, applies routes, rules, nftables, dnsmasq.
- `scripts/update-ru-geoip.sh` - downloads RU IPv4 CIDRs and loads the nft set.
- `scripts/update-manual-rules.sh` - loads manual force-RU and force-FI IP/CIDR overrides.
- `scripts/check-domain-egress.sh` - explains the expected egress path for a domain.
- `scripts/status.sh` - prints current policy routing and nft set status.
- `scripts/remove.sh` - removes runtime rules created by this package.
- `scripts/verify-render-local.sh` - verifies template rendering without root.
- `systemd/*.service`, `systemd/*.timer` - optional boot and daily GeoIP update.

## Install on the VPS

Copy this directory to the VPS, then run:

```bash
cd wireguard-split-ru
sudo bash scripts/install-packages-ubuntu.sh
sudo bash scripts/install.sh
sudo nano /etc/splitvpn/splitvpn.env
sudo bash /opt/splitvpn/scripts/ensure-wireguard-configs.sh
sudo systemctl enable --now wg-quick@wg0.service wg-quick@wg1.service
sudo bash /opt/splitvpn/scripts/apply.sh
sudo bash /opt/splitvpn/scripts/update-ru-geoip.sh
```

`ensure-wireguard-configs.sh` never overwrites existing WireGuard configs. If
`wg1.conf` is missing and `WG1_PRIVATE_KEY` is empty, it generates a new server
private key locally and prints the public key. `wg0.conf` is generated only when
the FI peer data and RU private key are present in `/etc/splitvpn/splitvpn.env`.

## Manual overrides

Edit these files on the VPS:

```bash
sudo nano /etc/splitvpn/force-ru.txt
sudo nano /etc/splitvpn/force-fi.txt
```

Each line may be a domain, wildcard domain, IPv4 address, or IPv4 CIDR:

```text
# comments are allowed
example.com
*.example.com
203.0.113.10
203.0.113.0/24
```

Priority is:

```text
force-fi.txt > force-ru.txt > .ru DNS classification > RU GeoIP > default FI
```

After editing, apply changes:

```bash
sudo /opt/splitvpn/scripts/apply.sh
```

Domain entries take effect as clients resolve them through the VPS dnsmasq.
IP/CIDR entries take effect immediately when `apply.sh` loads nftables sets.

## Domain egress check

On the VPS:

```bash
sudo /opt/splitvpn/scripts/check-domain-egress.sh vk.com
```

From Windows, use the optional helper in `examples/check-domain-egress.ps1`:

```powershell
.\check-domain-egress.ps1 vk.com
```

The checker shows resolved IPv4 addresses, the matching rule reason, expected
egress path, and the route selected by policy routing.

Optional systemd enablement:

```bash
sudo systemctl enable --now splitvpn.service
sudo systemctl enable --now splitvpn-geoip.timer
```

For the current two-hop layout, also enable WireGuard at boot:

```bash
sudo systemctl enable --now wg-quick@wg0.service
sudo systemctl enable --now wg-quick@wg1.service
```

`wg1` is ordered after `wg0`, and `splitvpn.service` is ordered after both.
The GeoIP timer runs nightly at 04:20 local server time, with up to 30 minutes
of randomized delay.

## Important assumptions

- Client ingress interface is `wg1`.
- FI egress tunnel is `wg0`.
- RU direct egress is `dev0`.
- IPv4 forwarding is required and enabled by `apply.sh`.
- Ubuntu 22.04 `dnsmasq` is supported through the `ipset` fallback because its
  package is commonly built with `ipset no-nftset`.
- IPv6 is not configured here. Disable IPv6 for VPN clients or add matching
  IPv6 sets/routes before advertising IPv6 to clients.
- Clients should use the VPS DNS address on `wg1`. UDP/TCP port 53 from clients
  is redirected locally by default, but DoH/DoT cannot be transparently
  classified as `.ru`.

## Safety notes

Run this from an SSH session that has out-of-band recovery available. The
scripts avoid changing WireGuard peer configs and run `nft -c` before loading
the firewall, but firewall and routing changes can still disconnect a VPS if
interface names or gateways are wrong.

If `dnsmasq` cannot bind to port 53, check `systemd-resolved`:

```bash
sudo ss -lntup 'sport = :53'
```

Either make `dnsmasq` listen only on the WireGuard address from
`DNS_LISTEN_ADDRESS`, or disable the local stub listener in
`/etc/systemd/resolved.conf`.
