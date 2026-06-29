# AmneziaWG Server — Home Assistant Add-on Repository

[![Add repository to your Home Assistant instance](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fkitos9112%2Fhassio-addon-amneziawg)

[![CI](https://github.com/kitos9112/hassio-addon-amneziawg/actions/workflows/ci.yaml/badge.svg)](https://github.com/kitos9112/hassio-addon-amneziawg/actions/workflows/ci.yaml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

An open-source Home Assistant add-on that runs an **AmneziaWG** VPN **exit node** on your
Home Assistant host. Remote clients connect from the internet and route their traffic
(full tunnel) out through your home connection. AmneziaWG is a WireGuard fork that adds
DPI-evasion obfuscation; with obfuscation disabled it is byte-for-byte plain WireGuard.

> **Heads-up on transport:** AmneziaWG/WireGuard is **UDP**. **Cloudflare Tunnel cannot
> carry it** (its public ingress is HTTP/HTTPS only; the only Cloudflare product that
> proxies arbitrary UDP is Spectrum, which is Enterprise-only). You need a real public
> UDP endpoint — a router **port-forward + DDNS** (this repo's documented path), or a
> cheap VPS UDP relay if you are behind CGNAT. See [DOCS](amneziawg/DOCS.md#exposing-the-server).

## What it does

- Userspace **`amneziawg-go`** + **`amneziawg-tools`** — **no kernel module**, so it works
  on Home Assistant OS regardless of kernel. Builds for **amd64** and **aarch64**.
- Generates and **persists** server + per-client keys in `/data` (idempotent — restarts
  never rotate keys unless you ask).
- Declarative **clients list**; exports each client's `.conf` + **QR** to a share, and
  optionally prints a scannable QR to the add-on log.
- Enables **IPv4 forwarding + NAT/masquerade**, with clean teardown on stop.
- Configurable UDP port (default `51820`, **`<1024` allowed**), subnet, DNS, MTU,
  AllowedIPs, keepalive, and AmneziaWG obfuscation parameters.

## Install

**Option A — add this repository (recommended)**

Click the badge at the top to add the repository in one step, or manually:

1. Settings → Add-ons → Add-on Store → ⋮ → **Repositories**.
2. Paste `https://github.com/kitos9112/hassio-addon-amneziawg` and **Add**.
3. Install **AmneziaWG Server** from the store, configure, start.

Installs pull prebuilt multi-arch images (amd64/aarch64) from GHCR — no on-device build.

**Option B — local add-on**

Copy the `amneziawg/` folder into your Home Assistant `/addons` share (via the Samba or
Studio Code Server / File editor add-on), then refresh the Add-on Store and install
**AmneziaWG Server** under *Local add-ons*.

Full setup, router port-forwarding, DDNS, client apps, verification, tuning and risks are
in **[amneziawg/DOCS.md](amneziawg/DOCS.md)**.

## Repository layout

```
addon-amneziawg/
├── repository.yaml          # registers this as an HA add-on repo
├── amneziawg/               # the add-on
│   ├── config.yaml  build.yaml  Dockerfile  apparmor.txt
│   ├── README.md  DOCS.md  CHANGELOG.md  translations/en.yaml
│   └── rootfs/              # s6 service + /usr/lib/amneziawg/*.sh
├── tests/                   # test-render.sh (pure logic) + test-smoke.sh (container)
└── docs/superpowers/        # design spec + implementation plan
```

## Development / tests

```bash
bash tests/test-render.sh    # pure-logic: validation, key gen, rendering, export (no root)
bash tests/test-smoke.sh     # integration: builds image, brings iface up, checks NAT (needs Docker)
```

## License & scope

Private add-on for personal use. No secrets are stored in git; your public IP/domain is a
runtime option, never hardcoded. See [DOCS — Risks](amneziawg/DOCS.md#risks-and-limitations).
