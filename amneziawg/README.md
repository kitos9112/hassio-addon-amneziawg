# AmneziaWG Server

AmneziaWG (WireGuard-compatible, DPI-evading) VPN **exit node** for Home Assistant.
Remote clients connect from the internet and route their traffic out through your HASS host.

## Highlights

- Userspace `amneziawg-go` — **no kernel module** (works on Home Assistant OS). amd64 + aarch64.
- Server + client keys generated and **persisted** in `/data`; idempotent across restarts.
- Declarative client list → exports `.conf` + QR to `/addon_configs/local_amneziawg/clients/`.
- IPv4 forwarding + NAT with clean teardown.
- Obfuscation **on by default** (set it off for plain-WireGuard compatibility).
- Configurable UDP port (default `51820`, sub-1024 allowed), subnet, DNS, MTU, AllowedIPs, keepalive.

## Quick start

1. Install and open the add-on.
2. Set **`endpoint_host`** to your public IP or DDNS hostname (required).
3. Add client names under **`clients`** (a default `phone` client is pre-filled).
4. Start the add-on.
5. **Forward the UDP port** (default `51820`) on your router to the Home Assistant host.
6. Grab each client's config/QR from `/addon_configs/local_amneziawg/clients/` (Samba / File
   editor add-on) or scan the QR printed in the add-on log with the **Amnezia** app.

> Obfuscation is on by default, so clients must use the **Amnezia app** or **`awg`** —
> stock WireGuard clients will **not** connect until you set `obfuscation.enabled: false`.

See **DOCS** (the Documentation tab) for router/DDNS setup, adding clients, verification,
tuning and risks.
