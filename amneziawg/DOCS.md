# AmneziaWG Server — Documentation

An AmneziaWG VPN **exit node** for Home Assistant. Remote clients connect from the
internet and send their traffic out through your Home Assistant host's connection.

- [How AmneziaWG differs from WireGuard](#how-amneziawg-differs-from-wireguard)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration options](#configuration-options)
- [Exposing the server](#exposing-the-server) (router port-forward + DDNS)
- [Client apps](#client-apps)
- [Adding a client](#adding-a-client)
- [Retrieving a client config / QR](#retrieving-a-client-config--qr)
- [Using a low / well-known port](#using-a-low--well-known-port)
- [Verifying traffic exits via Home Assistant](#verifying-traffic-exits-via-home-assistant)
- [Tuning: DNS, MTU, AllowedIPs, keepalive, endpoint](#tuning)
- [Plain WireGuard mode](#plain-wireguard-mode)
- [Regenerating keys](#regenerating-keys)
- [Risks and limitations](#risks-and-limitations)
- [Troubleshooting](#troubleshooting)

## How AmneziaWG differs from WireGuard

AmneziaWG is a WireGuard fork that adds **obfuscation** (junk packets `Jc/Jmin/Jmax`,
handshake prefixes `S1/S2`, and header magic `H1–H4`) so deep-packet-inspection can't
fingerprint the traffic as WireGuard. The cryptography is identical to WireGuard.

- **Obfuscation ON (default):** clients **must** run AmneziaWG (the Amnezia app or `awg`).
  Stock WireGuard clients cannot connect.
- **Obfuscation OFF:** with the obfuscation parameters cleared, it is byte-for-byte plain
  WireGuard and any WireGuard client works. See [Plain WireGuard mode](#plain-wireguard-mode).

This add-on runs the **userspace** implementation (`amneziawg-go`), so it needs **no kernel
module** — important because Home Assistant OS ships a custom kernel.

## Requirements

- A way for clients to reach a **public UDP port** on your Home Assistant host — see
  [Exposing the server](#exposing-the-server). **Cloudflare Tunnel will not work** (UDP).
- The add-on uses `host_network`, `NET_ADMIN`, and `/dev/net/tun` (all declared in its
  config). These are required for a VPN exit node.

## Installation

**Add the repository:** Settings → Add-ons → Add-on Store → ⋮ → Repositories → add this
repo's URL → install **AmneziaWG Server**.

**Or local:** copy the `amneziawg/` folder into the `/addons` share (Samba or File editor
add-on), refresh the store, install from *Local add-ons*.

On first start the add-on generates the server keypair and per-client keys, writes them to
`/data`, brings the interface up, and exports client configs.

## Configuration options

| Option | Default | Meaning |
|---|---|---|
| `server_port` | `51820` | UDP listen port. `<1024` allowed. Must not clash with another host service. |
| `endpoint_host` | _(required)_ | Your public IP or DDNS hostname. Written into client configs as `Endpoint`. |
| `vpn_subnet` | `10.13.13.0/24` | Tunnel subnet (IPv4). Server takes `.1`; clients get the rest. |
| `client_dns` | `["1.1.1.1"]` | DNS server(s) pushed to clients. |
| `allowed_ips` | `0.0.0.0/0` | What clients route through the tunnel. `0.0.0.0/0` = full-tunnel exit. |
| `mtu` | `1420` | Interface MTU. Lower (e.g. `1280`) if you see fragmentation. |
| `persistent_keepalive` | `25` | Keepalive seconds (keeps NAT mappings alive). `0` disables. |
| `enable_nat` | `true` | Masquerade client traffic out the host WAN. |
| `regenerate_clients` | `false` | One-shot: rotate **all** client keys on next start. Reset to `false` after. |
| `qr_in_log` | `true` | Print a scannable QR per client to the log (encodes the private key — see risks). |
| `obfuscation.enabled` | `true` | DPI-evasion. `false` ⇒ plain WireGuard. |
| `obfuscation.jc/jmin/jmax/s1/s2/h1..h4` | _(auto)_ | Leave empty to auto-generate + persist. Set to pin exact values. |
| `clients[].name` | `phone` | Client name (`a-z A-Z 0-9 -`, ≤32). |
| `clients[].address` | _(auto)_ | Optional fixed tunnel IP inside `vpn_subnet`. |
| `clients[].allowed_ips` | _(global)_ | Optional per-client override of routed ranges. |

Example:

```yaml
server_port: 51820
endpoint_host: vpn.example.duckdns.org
vpn_subnet: 10.13.13.0/24
client_dns:
  - 1.1.1.1
allowed_ips: 0.0.0.0/0
mtu: 1420
persistent_keepalive: 25
enable_nat: true
obfuscation:
  enabled: true
clients:
  - name: phone
  - name: laptop
    address: 10.13.13.50
```

## Exposing the server

AmneziaWG/WireGuard is **UDP**. You need a real public UDP endpoint.

### Recommended: router UDP port-forward + DDNS (you have a public IP)

1. **DDNS** (if your IP changes): set up a dynamic-DNS name (e.g. DuckDNS — there is a HA
   add-on — or Cloudflare DNS via API). Put that hostname in `endpoint_host`.
2. **Port-forward** on your router: forward **UDP `<server_port>`** (default `51820`) to the
   **Home Assistant host's LAN IP**. Protocol must be **UDP** (not TCP).
3. Open that UDP port in any upstream firewall.

> **Why not Cloudflare Tunnel?** Cloudflare Tunnel's public ingress is HTTP/HTTPS only and
> exposes no public UDP listener. Spectrum (the only Cloudflare product that proxies UDP)
> is Enterprise-only. Wrapping WireGuard over TCP/WebSocket through Cloudflare's HTTP proxy
> is broken by request buffering and violates its ToS. Use a direct port-forward or a VPS.

### Behind CGNAT or want to hide your home IP: VPS UDP relay

If your ISP uses CGNAT (no real public IP), a port-forward cannot work. Rent a small VPS
with a public IP and relay UDP to home — e.g. run WireGuard on the VPS with your home as a
peer and `iptables` DNAT/forward `:<port>/udp` to the home tunnel IP, or use `socat`/
`wstunnel`. Set `endpoint_host` to the VPS hostname. (Out of scope for this add-on; it just
runs the server.)

## Client apps

Because obfuscation is on by default, clients must speak AmneziaWG:

- **Amnezia VPN app** (Android/iOS/Windows/macOS/Linux) — import the `.conf` or scan the QR.
- **`awg` / `awg-quick`** (amneziawg-tools) on Linux.

If you switch to [plain WireGuard mode](#plain-wireguard-mode), any WireGuard client works.

## Adding a client

1. Add an entry under `clients` (just a `name`, optionally a fixed `address`).
2. Restart the add-on. Existing clients keep their keys; only the new client gets fresh keys.
3. Retrieve its config/QR (below).

## Retrieving a client config / QR

The add-on writes each client's config and QR PNG to the add-on config share:

```
/addon_configs/local_amneziawg/clients/<name>.conf
/addon_configs/local_amneziawg/clients/<name>.png
```

Access them with the **Samba share** add-on or the **Studio Code Server / File editor**
add-on. With `qr_in_log: true` a scannable QR is also printed in the add-on **Log** tab —
scan it directly with the Amnezia app.

> The `.conf`/QR contain the client **private key**. Treat them as secrets; the add-on
> stores them mode `600` and never commits them to git.

## Using a low / well-known port

Set `server_port` to a value below 1024 (e.g. `443` to look like QUIC/HTTP3) to slip past
restrictive firewalls. The container runs as root with `host_network`, so low ports bind
fine. **Caveat:** because networking is shared with the host, the port must not already be
in use — e.g. **don't pick `53`** if you run AdGuard/Pi-hole, and don't pick a port another
add-on listens on. Combined with obfuscation, a well-known port is a solid evasion setup.

## Verifying traffic exits via Home Assistant

1. Connect a client and confirm a handshake: the client app shows a recent handshake; on the
   server, the add-on log / `awg show awg0` lists the peer with a handshake time.
2. On the connected client, check your public IP:

   ```bash
   curl https://ifconfig.me        # or visit https://ifconfig.me in a browser
   ```

   It should show **your home's public IP**, not the client's normal one.
3. Confirm DNS: `nslookup example.com` should use the `client_dns` you set.

## Tuning

- **`endpoint_host`** — must resolve to your public IP from the internet. With DDNS, point
  it at the DDNS name so it survives IP changes.
- **`client_dns`** — `1.1.1.1`/`8.8.8.8`, or a local resolver reachable through the tunnel
  (e.g. the server tunnel IP if you run DNS on HASS).
- **`mtu`** — `1420` suits most links. If sites hang/half-load, lower to `1380` or `1280`
  (obfuscation/junk adds overhead). Set it the same on both ends (the client config inherits it).
- **`allowed_ips`** — `0.0.0.0/0` = full tunnel (all IPv4 via HASS). For split tunnel, list
  only the ranges you want routed (e.g. `10.13.13.0/24, 192.168.1.0/24`). Per-client override
  via `clients[].allowed_ips`. **IPv6:** default config is IPv4-only; to route IPv6 you must
  add an IPv6 subnet and include `::/0` yourself (otherwise leave it out to avoid blackholing v6).
- **`persistent_keepalive`** — `25` keeps NAT/firewall mappings open so the server can reach
  roaming clients; `0` to disable.

## Plain WireGuard mode

Set `obfuscation.enabled: false` and restart. The generated configs then contain no
`Jc/S1/H1…` lines and behave as standard WireGuard — any WireGuard client can connect. You
lose DPI evasion. (Switching modes does not change keys.)

## Regenerating keys

Set `regenerate_clients: true` and restart to rotate **all** client keys (and any
auto-generated obfuscation parameters). **Set it back to `false`** afterwards, or keys
rotate on every restart. Re-distribute the new client configs. The server key is **not**
rotated (that would break every client); it persists in `/data/server_private.key`.

## Risks and limitations

- **Exposing a VPN from home** gives connected clients your home IP and a path into your
  network scope (constrained here to internet egress via NAT). Only share client configs
  with people/devices you trust.
- **CGNAT:** if your ISP gives you a shared (CGNAT) address, inbound port-forwarding will
  not work — use a [VPS relay](#behind-cgnat-or-want-to-hide-your-home-ip-vps-udp-relay).
- **Dynamic IP:** residential IPs change; use **DDNS** and set `endpoint_host` to the name.
- **Cloudflare Tunnel cannot carry this** (UDP). Don't try to route it through Cloudflare.
- **Privileges:** the add-on needs `host_network`, `NET_ADMIN`, and `/dev/net/tun`. This is
  inherent to running a routing VPN. It does **not** request `SYS_MODULE` or `full_access`.
- **Kernel/TUN:** requires `/dev/net/tun`; the add-on checks for it and fails fast with a
  clear message if missing.
- **`qr_in_log`:** the logged QR encodes the full client config including its private key.
  Set `qr_in_log: false` if you forward/share add-on logs.
- **Performance:** userspace AmneziaWG has a bit more overhead than a kernel module — fine
  for a home exit node, but not a multi-gigabit appliance.

## Troubleshooting

- **No handshake:** confirm the router forwards **UDP** `<server_port>` to the HASS host;
  confirm `endpoint_host` resolves from the internet; confirm the client uses the **Amnezia
  app/`awg`** (not stock WireGuard) while obfuscation is on; check the client's obfuscation
  params match (they come from the exported config — re-export if you changed them).
- **Starts then traffic doesn't route:** ensure `enable_nat: true`; check the log for the
  detected WAN interface and the `NAT on:` line.
- **Port already in use:** pick a different `server_port` (host networking shares ports).
- **AppArmor `DENIED` in the log:** set `apparmor: false` in the add-on config as a
  temporary workaround and report it.
- **`/dev/net/tun missing`:** your environment doesn't expose TUN; the add-on cannot run a
  userspace VPN there.
