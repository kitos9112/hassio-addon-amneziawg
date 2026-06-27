# AmneziaWG Server — Home Assistant Add-on — Design Spec

- **Date:** 2026-06-27
- **Status:** Approved (brainstorming → implementation)
- **Author:** marcos.soutullo (with Claude Code)

## 1. Goal

A private Home Assistant add-on that runs an **AmneziaWG** (WireGuard fork with DPI-evasion
obfuscation) VPN **server / exit node** on the Home Assistant host. Remote clients connect from
outside and route their Internet traffic (full tunnel) out through the HASS box. Designed to run on
a low/well-known UDP port for easier traversal, with obfuscation on by default.

## 2. Feasibility findings (validated 2026-06-27, current docs)

1. **Cloudflare Tunnel cannot carry the VPN.** WireGuard/AmneziaWG is UDP; Cloudflare Tunnel public
   ingress is HTTP/HTTPS only. Spectrum (the only Cloudflare product proxying arbitrary UDP) is
   Enterprise-only + paid + dedicated IP. Wrapping WG-over-TCP/WebSocket *through* Cloudflare's HTTP
   proxy is broken by request buffering and violates Cloudflare ToS. → **Cloudflare is out as the VPN
   transport.** Cloudflare DNS may still be used for DDNS (separate concern).
   - Sources: https://developers.cloudflare.com/spectrum/ , https://developers.cloudflare.com/spectrum/protocols-per-plan/ , https://github.com/cloudflare/cloudflared/issues/1557
2. **AmneziaWG runs headless in userspace** via `amneziawg-go` + `amneziawg-tools` (`awg`,
   `awg-quick`) over `/dev/net/tun` with `CAP_NET_ADMIN` — **no kernel module**, so no HAOS custom
   kernel dependency. Both repos actively maintained (commits June 2026). Cross-compiles to amd64 and
   aarch64.
   - Sources: https://github.com/amnezia-vpn/amneziawg-go , https://github.com/amnezia-vpn/amneziawg-tools
3. **Obfuscation breaks stock-WireGuard compatibility by design.** With obfuscation params set,
   clients MUST use the Amnezia app or `awg`. With all params zero/absent it is byte-for-byte plain
   WireGuard, interoperable with stock `wg` clients. → single per-deployment toggle.
   - Source: https://docs.amnezia.org/documentation/amnezia-wg/
4. **HA add-on model:** mirror the community WireGuard add-on (`hassio-addons/addon-wireguard`),
   which itself ships userspace `wireguard-go`. Base image `ghcr.io/hassio-addons/base` (s6 + bashio),
   `init: false`, `privileged: [NET_ADMIN]`, `devices: ["/dev/net/tun"]`, ship `build.yaml` (the
   no-build.yaml default was removed in Supervisor 2026.04.0). Local add-on install via Samba drop into
   `/addons` or by adding the git repo URL.
   - Sources: https://developers.home-assistant.io/docs/add-ons/configuration/ , https://github.com/hassio-addons/addon-wireguard

## 3. Decisions (from brainstorming Q&A)

| Decision | Choice |
|---|---|
| Implementation | AmneziaWG **userspace** (`amneziawg-go` + `amneziawg-tools`), no kernel module |
| Arch | `amd64` + `aarch64` (both technically valid) |
| Exposure | **Public IP: router UDP port-forward + DDNS** (documented). VPS-relay noted as CGNAT alternative |
| Obfuscation | **ON by default**, fully configurable; zeroing params → plain-WG compatible |
| Default port | **51820**, fully configurable incl. `<1024` |
| Client delivery | **Files + QR** written to a mapped share **and** QR printed to the add-on log. **No web UI** |
| Routing | Full-tunnel exit node; default `allowed_ips = 0.0.0.0/0` (IPv4); IPv6 opt-in |

## 4. Architecture

- One add-on (`slug: amneziawg`) in a one-add-on local repo.
- `awg-quick up awg0` brings the interface up using the userspace `amneziawg-go` backend
  (`WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go`), driven by a generated `/data/awg0.conf`.
- NAT/forwarding handled by an explicit, auditable `network.sh` (NOT embedded as PostUp in the
  `.conf`), so it is independently testable; `finish` guarantees teardown on stop/crash.
- s6 service supervises a small watchdog loop; if `awg show awg0` fails, the service exits non-zero so
  the Supervisor restarts it (after `finish` cleanup).
- All persistent state (keys, obfuscation params, rendered server config, runtime markers) lives in
  `/data`. Client exports go to a mapped per-add-on config dir.

### 4.1 Repo layout

```
addon-amneziawg/
├── repository.yaml
├── README.md
├── .gitignore
├── docs/superpowers/specs/2026-06-27-amneziawg-server-addon-design.md
├── amneziawg/
│   ├── config.yaml
│   ├── build.yaml
│   ├── Dockerfile
│   ├── apparmor.txt
│   ├── README.md
│   ├── DOCS.md
│   ├── CHANGELOG.md
│   ├── translations/en.yaml
│   └── rootfs/
│       ├── etc/services.d/amneziawg/run
│       ├── etc/services.d/amneziawg/finish
│       └── usr/lib/amneziawg/
│           ├── common.sh      # logging helpers, constants, /data paths
│           ├── validate.sh    # option validation
│           ├── keys.sh        # key + obfuscation param generation/persistence
│           ├── render.sh      # render awg0.conf + client .conf
│           ├── network.sh     # ip_forward + NAT up/down
│           └── export.sh      # write client .conf + QR; log QR
└── tests/
    ├── options.sample.json
    ├── test-render.sh         # pure-logic: validate + render, no root
    ├── test-smoke.sh          # privileged container: iface up, NAT, forward, teardown
    └── lib/assert.sh
```

## 5. `config.yaml` manifest

- `arch: [amd64, aarch64]`
- `init: false`, `startup: application`, `boot: auto`
- `host_network: true` (masquerade out host WAN; clients exit via host; low-port bind on host)
- `privileged: [NET_ADMIN]`; `devices: ["/dev/net/tun"]`; **no** `full_access`/`SYS_MODULE`
- `map: ["addon_config:rw"]` → exports at `/config/clients/` (host: `/addon_configs/local_amneziawg/clients/`)
- `ports: {"51820/udp": 51820}` + `ports_description` (UI/router hint only; with `host_network` the
  effective port is `server_port`)
- `apparmor: true` with a shipped `apparmor.txt` profile (documented toggle if it blocks tun/iptables)
- `image:` omitted → local build from `Dockerfile`

## 6. Options schema (maps the target spec 1:1)

```yaml
options:
  server_port: 51820
  endpoint_host: ""                 # REQUIRED at runtime
  vpn_subnet: "10.13.13.0/24"
  client_dns: ["1.1.1.1"]
  allowed_ips: "0.0.0.0/0"
  mtu: 1420
  persistent_keepalive: 25
  enable_nat: true
  regenerate_clients: false
  obfuscation:
    enabled: true
  clients:
    - name: "phone"
schema:
  server_port: int(1,65535)
  endpoint_host: str
  vpn_subnet: str
  client_dns:
    - str
  allowed_ips: str
  mtu: int(1280,1500)
  persistent_keepalive: int(0,65535)
  enable_nat: bool
  regenerate_clients: bool
  obfuscation:
    enabled: bool
    jc: int(0,128)?
    jmin: int(0,1280)?
    jmax: int(0,1280)?
    s1: int(0,1280)?
    s2: int(0,1280)?
    h1: int(5,2147483647)?
    h2: int(5,2147483647)?
    h3: int(5,2147483647)?
    h4: int(5,2147483647)?
  clients:
    - name: match(^[a-zA-Z0-9][a-zA-Z0-9-]{0,31}$)
      address: str?
      allowed_ips: str?
  log_level: list(trace|debug|info|notice|warning|error|fatal)?
```

Semantics:
- `endpoint_host` → client `Endpoint = endpoint_host:server_port`. Required (validation fails if empty).
- `allowed_ips` → goes into the **client** config `AllowedIPs` (what the client routes through us).
  Default `0.0.0.0/0` = full-tunnel IPv4. Per-client override via `clients[].allowed_ips`.
- Server peer `AllowedIPs` for each client = that client's VPN `/32` (auto-derived).
- `vpn_subnet` → server takes `.1`; clients auto-assigned ascending (`.2`, `.3`, …) unless a fixed
  `address` is given.
- `client_dns` → client config `DNS`.

## 7. Obfuscation parameter generation

When `obfuscation.enabled: true` and a param is unset, generate **once** and persist to
`/data/obfuscation.env` (so server and clients always match and restarts don't change them unless
requested). Defaults / constraints:
- `Jc` random 4–12; `Jmin` random 8–32; `Jmax` random 64–128 with `Jmax > Jmin`.
- `S1` random 15–150; `S2` random 15–150 with `S1 != S2` **and** `S2 != S1 + 56`
  (avoid `148+S1 == 92+S2`).
- `H1..H4` distinct random in `[5, 2147483647]`, all different and not in `{1,2,3,4}`.
- Explicit user-supplied values override generated ones (and are validated against the same constraints).
- `regenerate_clients: true` also regenerates obfuscation params if they were auto-generated.
- When `obfuscation.enabled: false`, omit all Jc/Jmin/Jmax/S1/S2/H1..H4 lines → plain WireGuard.

## 8. Runtime flow

`run`:
1. `common.sh` sets paths, log level.
2. `validate.sh` — fail fast (see §9).
3. `keys.sh` — server keypair generated only if absent; per-client keys + PSK generated only if absent;
   obfuscation params generated/persisted; honors `regenerate_clients`.
4. `render.sh` — write `/data/awg0.conf` (chmod 600); never logged.
5. `network.sh up` — `sysctl -w net.ipv4.ip_forward=1`; detect WAN iface
   (`ip route show default | awk '/default/{print $5; exit}'`); add rules tagged
   `-m comment --comment amneziawg-addon`:
   - `iptables -t nat -A POSTROUTING -s <vpn_subnet> -o <wan> -j MASQUERADE`
   - `iptables -A FORWARD -i awg0 -j ACCEPT`
   - `iptables -A FORWARD -o awg0 -m state --state RELATED,ESTABLISHED -j ACCEPT`
   - persist `<wan>` + `<vpn_subnet>` to `/data/.runtime` for exact teardown.
   - skipped if `enable_nat: false`.
6. `awg-quick up awg0`.
7. `export.sh` — write `/config/clients/<name>.conf` + `<name>.png` (QR); print QR (ANSI) + summary
   to log.
8. Watchdog: `while awg show awg0 >/dev/null 2>&1; do sleep N & wait $!; done; exit 1`.

`finish` (runs on stop and on service crash):
1. `awg-quick down awg0` (ignore errors).
2. `network.sh down` — delete only rules tagged `amneziawg-addon`, using stored `<wan>`/`<vpn_subnet>`.
3. Restore `net.ipv4.ip_forward` to its prior value (saved in `/data/.runtime`).

## 9. Validation rules (fail fast, never leak secrets)

- `endpoint_host` non-empty.
- `vpn_subnet` valid CIDR; `allowed_ips` each entry valid CIDR.
- No duplicate `clients[].name`.
- `clients[].address` (if set) valid, inside `vpn_subnet`, not `.1`, no duplicates/overlaps.
- Auto-assignment has enough host addresses for the client count.
- `/dev/net/tun` exists and is usable; report actionable error if NET_ADMIN/tun missing.
- Obfuscation: `Jmax > Jmin`; `S1 != S2`; `S2 != S1 + 56`; `H1..H4` distinct & not in `{1,2,3,4}`.
- Warn (not fail) if `server_port` already bound on host (`ss -lun`), and on host-network port hints.
- Arch sanity: warn if `uname -m` not in supported set.

## 10. Logging & secrets policy

- Private keys, PSKs, and `awg0.conf` contents are **never** printed.
- Logs show: chosen port, subnet, WAN iface, NAT on/off, obfuscation on/off, per-client **public key
  fingerprint** (short hash) and assigned IP, export paths.
- `.gitignore` excludes `/data`, `**/clients/`, `*.key`, `tests/tmp/`, `.claude/settings.local.json`.
- Repo contains no real keys, no public IP/domain (all via options).

## 11. Testing

- `tests/test-render.sh` (no root): runs `validate.sh` + `keys.sh` + `render.sh` against
  `options.sample.json` in a temp `/data`, asserts:
  - server `awg0.conf` has `[Interface]`, `PrivateKey`, `ListenPort`, obfuscation lines (Jc/H1..H4),
    one `[Peer]` per client with correct `AllowedIPs = <ip>/32`.
  - each client `.conf` has `Endpoint`, `DNS`, `AllowedIPs`, obfuscation lines, server public key.
  - idempotency: second run does not change keys; duplicate-name / bad-CIDR fixtures fail.
- `tests/test-smoke.sh` (Docker + `--cap-add=NET_ADMIN --device=/dev/net/tun`): build image, run
  `network.sh up` + `awg-quick up`, assert `awg show awg0`, `iptables -t nat -S | grep MASQUERADE`,
  `sysctl net.ipv4.ip_forward == 1`; then teardown and assert tagged rules removed.
- Documented `docker build` per arch as a build-acceptance check.

## 12. Docs deliverables

- **Repo README.md**: what it is, feasibility summary, install.
- **amneziawg/DOCS.md** (in-UI): options reference, router UDP port-forward + DDNS, client apps
  (Amnezia/`awg`), add a client, retrieve config/QR, verify exit via HASS, MTU/DNS/AllowedIPs/keepalive
  tuning, Risks section (home exposure, CGNAT, dynamic IP/DDNS, NET_ADMIN/host-network, kernel/tun,
  Cloudflare-won't-work).
- **amneziawg/CHANGELOG.md**: start at `1.0.0`.

## 13. Acceptance criteria mapping

| Criterion | Met by |
|---|---|
| Builds locally | `Dockerfile` + `build.yaml`, multi-stage; `docker build` check |
| Starts cleanly | `run`/`finish` s6 service, watchdog |
| Server private key persists in `/data` | `keys.sh` idempotent |
| Client config generated/exported | `render.sh` + `export.sh` (files + QR) |
| Remote client routes `0.0.0.0/0` via HASS | `allowed_ips` default + `network.sh` NAT |
| Useful logs, no key leaks | §10 |
| README sufficient | §12 |

## 14. Known limitations

- Obfuscation-on requires Amnezia/`awg` clients (not stock `wg`).
- Needs a real public IP; **CGNAT breaks the port-forward path** (VPS relay is the alternative).
- Dynamic IP requires DDNS.
- `host_network` means `server_port` must not collide with another host service (e.g. AdGuard on 53).
- IPv6 full-tunnel is opt-in (default v4 to avoid blackholing v6).
- AmneziaWG userspace has slightly higher overhead than a kernel module (acceptable for a home exit node).

## 15. Non-goals

No desktop GUI; no secrets in git; no hardcoded public IP/domain; no SSH exposure; no dependency on
community add-ons (we build our own).
