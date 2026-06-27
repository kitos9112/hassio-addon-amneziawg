# AmneziaWG Server Add-on — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Home Assistant add-on that runs an AmneziaWG (userspace) VPN exit node, generating server/client keys + configs, NAT-routing client traffic to the Internet via the HASS host.

**Architecture:** Userspace `amneziawg-go` + `amneziawg-tools` in an Alpine s6/bashio add-on. `run.sh` reads add-on options via bashio, exports them as a plain env + clients TSV contract, then small sourced libs (validate/keys/render/network/export) do the work. `awg-quick up awg0` brings the interface up; explicit `network.sh` does NAT; s6 `finish` guarantees teardown.

**Tech Stack:** Alpine (`ghcr.io/hassio-addons/base`), s6-overlay, bashio, Go (build only), amneziawg-go `v0.2.19`, amneziawg-tools `v1.0.20260618-2`, iptables, qrencode.

## Global Constraints

- arch: `amd64`, `aarch64` only.
- Privileges: `host_network: true`, `privileged: [NET_ADMIN]`, `devices: ["/dev/net/tun"]`. No `full_access`, no `SYS_MODULE`.
- Persist all state in `/data`; client exports to `/config/clients/` (mapped `addon_config`).
- Idempotent: restart never rotates keys unless `regenerate_clients: true`.
- Obfuscation ON by default; zeroing params ⇒ plain WireGuard.
- Default port 51820, configurable incl. `<1024`. Default subnet `10.13.13.0/24`. Default `allowed_ips` `0.0.0.0/0`.
- Never log private keys / PSKs / `awg0.conf` contents.
- Pins: amneziawg-go `v0.2.19`, amneziawg-tools `v1.0.20260618-2`.
- Full spec: `docs/superpowers/specs/2026-06-27-amneziawg-server-addon-design.md`.

## Inter-script contract (locked)

**Env vars** (set by `run.sh` from bashio, or by tests):
`SERVER_PORT, ENDPOINT_HOST, VPN_SUBNET, CLIENT_DNS (space-sep), ALLOWED_IPS, MTU,
PERSISTENT_KEEPALIVE, ENABLE_NAT (0|1), REGENERATE_CLIENTS (0|1),
OBFS_ENABLED (0|1), OBFS_JC, OBFS_JMIN, OBFS_JMAX, OBFS_S1, OBFS_S2, OBFS_H1..OBFS_H4 (empty ⇒ auto),
LOG_LEVEL, DATA_DIR (default /data), EXPORT_DIR (default /config/clients), IFACE (default awg0)`.

**Files:**
- `CLIENTS_TSV` (input, default `$DATA_DIR/.clients.input.tsv`): lines `name\taddress\tallowed_ips` (address/allowed_ips may be empty).
- `$DATA_DIR/.clients.resolved.tsv` (produced by keys.sh): `name\tip\tpubkey\tprivkey_file\tpsk_file\tallowed_ips`.
- `$DATA_DIR/server_private.key`, `server_public.key`, `obfuscation.env`, `.runtime`, `awg0.conf`.
- `$DATA_DIR/clients/<name>/{private.key,public.key,preshared.key}`.

**Function APIs:**
- common.sh: `log_info/warn/error/fatal`, `die <msg>`, `is_valid_cidr <c>`, `is_valid_ipv4 <ip>`, `cidr_host <subnet> <index>` (echoes Nth usable host), `cidr_prefix <subnet>`, `rand_int <min> <max>`, `key_fingerprint <pubkey>`.
- validate.sh: `validate_all` (exit≠0 + message on failure).
- keys.sh: `ensure_obfuscation`, `ensure_server_keys`, `resolve_clients` (gen per-client keys as needed + assign IPs ⇒ writes resolved TSV; honors `REGENERATE_CLIENTS`).
- render.sh: `render_server_conf`, `render_client_conf <name>` (stdout).
- network.sh: `nat_up`, `nat_down`.
- export.sh: `export_clients`.

---

### Task 1: Repo & add-on skeleton (manifest, build, translations)

**Files:**
- Create: `repository.yaml`, `amneziawg/config.yaml`, `amneziawg/build.yaml`, `amneziawg/translations/en.yaml`

**Steps:**
- [ ] Write `repository.yaml` (name/url/maintainer).
- [ ] Write `amneziawg/config.yaml` per spec §5/§6 (manifest + options + schema). Key points: `arch:[amd64,aarch64]`, `init:false`, `host_network:true`, `privileged:[NET_ADMIN]`, `devices:["/dev/net/tun"]`, `map:["addon_config:rw"]`, `ports:{"51820/udp":51820}`, full options+schema block (mtu has default ⇒ no `?`).
- [ ] Write `amneziawg/build.yaml` mapping both arches to `ghcr.io/hassio-addons/base:19.0.0` (verify tag exists in Task 2).
- [ ] Write `translations/en.yaml` with labels/descriptions for every option.
- [ ] Validate YAML parses (`python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('**/*.yaml',recursive=True)]"`). Expected: no error.
- [ ] Commit: `feat: add-on manifest, build config, translations`.

### Task 2: Dockerfile (multi-stage userspace build)

**Files:** Create `amneziawg/Dockerfile`

**Steps:**
- [ ] Confirm base image tag exists: `git ls-remote --tags https://github.com/hassio-addons/addon-base | sort -V | tail`. Pick latest `19.x` (fallback to a confirmed tag).
- [ ] Write multi-stage Dockerfile:
  - build stage `FROM ${BUILD_FROM}`: `apk add go git make build-base linux-headers bash`; `git clone --depth1 -b v0.2.19 amneziawg-go && make` → `/build/amneziawg-go`; `git clone --depth1 -b v1.0.20260618-2 amneziawg-tools && make -C src` → install `awg`,`awg-quick`.
  - final `FROM ${BUILD_FROM}`: `apk add --no-cache iptables ip6tables iproute2 bash libqrencode-tools openresolv`; copy binaries from build stage; `COPY rootfs /`; `ENV WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go WG_SUDO=0`; ensure scripts executable.
- [ ] `docker build` smoke (amd64) deferred to Task 13.
- [ ] Commit: `feat: multi-stage Dockerfile building amneziawg-go + amneziawg-tools`.

### Task 3: common.sh + test harness + fixtures (TDD foundation)

**Files:** Create `amneziawg/rootfs/usr/lib/amneziawg/common.sh`, `tests/lib/assert.sh`, `tests/options.sample.json`, `tests/test-render.sh`

**Steps:**
- [ ] Write `tests/lib/assert.sh`: `assert_eq`, `assert_contains <file> <pattern>`, `assert_not_contains`, `assert_file`, `assert_fail <cmd...>` (expects nonzero), counters + summary, exit≠0 on any failure.
- [ ] Write `tests/options.sample.json` mirroring spec defaults + 2 clients (`phone`, `laptop` with fixed `address`).
- [ ] Write `common.sh`: log_* wrap `bashio::log.*` if `command -v bashio` else echo to stderr with level prefix; `die`; `rand_int` via `/dev/urandom` (`od`); `cidr_prefix`; `is_valid_ipv4` (4 octets 0-255); `is_valid_cidr` (ipv4/prefix or ipv6 basic); `cidr_host <subnet> <idx>` (ipv4 math via arithmetic on the 32-bit int); `key_fingerprint` (`sha256` first 8 hex of pubkey).
- [ ] Write `tests/test-render.sh` skeleton: sets `DATA_DIR=$(mktemp -d)`, `EXPORT_DIR=$(mktemp -d)`, parses `options.sample.json` into the env/TSV contract (using `jq`), pre-seeds fake server+client keys if `awg`/`wg` absent, sources libs, runs `validate_all`, `ensure_obfuscation`, `ensure_server_keys`, `resolve_clients`, `render_server_conf`, asserts (filled in Tasks 4-6).
- [ ] Run `bash tests/test-render.sh`. Expected at this point: fails because validate/keys/render not yet written — confirms harness wiring (acceptable interim FAIL; will go green by Task 6).
- [ ] Commit: `test: harness, fixtures, common.sh helpers`.

### Task 4: validate.sh (test-first)

**Files:** Create `amneziawg/rootfs/usr/lib/amneziawg/validate.sh`; Modify `tests/test-render.sh`

**Steps:**
- [ ] Add assertions to test-render: valid sample passes `validate_all`; then `assert_fail` cases via env overrides in subshells — empty `ENDPOINT_HOST`, bad `VPN_SUBNET`, duplicate client names, `address` outside subnet, obfuscation `S2 == S1+56`.
- [ ] Run test → expect FAIL (validate.sh missing).
- [ ] Write `validate_all`: check endpoint non-empty; `is_valid_cidr VPN_SUBNET`; each `ALLOWED_IPS` entry valid CIDR; parse `CLIENTS_TSV` — dup names, valid/in-subnet/non-.1/non-dup addresses, host-count fits; if `OBFS_ENABLED=1` enforce `Jmax>Jmin`, `S1!=S2`, `S2!=S1+56`, H1..H4 distinct & ∉{1,2,3,4} (only when explicitly set); `/dev/net/tun` presence check is **warn-only** in tests (gated by `SKIP_TUN_CHECK`).
- [ ] Run test → expect PASS for validation block.
- [ ] Commit: `feat: option validation`.

### Task 5: keys.sh (test-first)

**Files:** Create `amneziawg/rootfs/usr/lib/amneziawg/keys.sh`; Modify `tests/test-render.sh`

**Steps:**
- [ ] Add assertions: after `ensure_server_keys`, `server_private.key`+`server_public.key` exist with mode 600 on private; capture pubkey, re-run, assert pubkey unchanged (idempotent). After `ensure_obfuscation`, `obfuscation.env` exists with valid in-range params; re-run unchanged. After `resolve_clients`, `.clients.resolved.tsv` has one line per client with correct sequential/fixed IPs.
- [ ] Run test → expect FAIL.
- [ ] Write keys.sh: `KEYGEN=${KEYGEN:-awg}`; helper `gen_privkey`/`pubkey`/`genpsk` calling `$KEYGEN`; if binary absent AND a `.fake_keys` marker set, synthesize deterministic base64 stubs (tests only). `ensure_server_keys` (gen iff missing or REGEN-not-applicable). `ensure_obfuscation` (load env if file exists else generate per spec §7 constraints, persist). `resolve_clients` (per client: ensure dir+keys+psk; assign fixed `address` or next free host from `.2`; emit resolved TSV; archive removed clients).
- [ ] Run test → expect PASS.
- [ ] Commit: `feat: idempotent key + obfuscation generation`.

### Task 6: render.sh (test-first) — turns test-render green

**Files:** Create `amneziawg/rootfs/usr/lib/amneziawg/render.sh`; Modify `tests/test-render.sh`

**Steps:**
- [ ] Add assertions: `render_server_conf` writes `awg0.conf` mode 600 with `[Interface]`, `PrivateKey`, `ListenPort = $SERVER_PORT`, `Address = <server .1>/<prefix>`, obfuscation lines (`Jc`,`H1`..`H4`) present when enabled, one `[Peer]` per client with `AllowedIPs = <ip>/32` and a `PresharedKey`. `render_client_conf phone` contains `Endpoint = host:port`, `DNS`, `AllowedIPs = 0.0.0.0/0`, obfuscation lines, server pubkey, no server private key. Negative: with `OBFS_ENABLED=0`, no `Jc/H1` lines in either.
- [ ] Run test → expect FAIL.
- [ ] Write render.sh: heredocs building server + client configs from env + resolved TSV + obfuscation.env; `chmod 600`.
- [ ] Run `bash tests/test-render.sh` → expect ALL PASS.
- [ ] Commit: `feat: server + client config rendering`.

### Task 7: network.sh (NAT up/down)

**Files:** Create `amneziawg/rootfs/usr/lib/amneziawg/network.sh`

**Steps:**
- [ ] Write `nat_up`: if `ENABLE_NAT=1`: `sysctl -w net.ipv4.ip_forward=1` (save prior to `.runtime`); detect WAN `ip route show default | awk '/default/{print $5; exit}'`; add MASQUERADE + 2 FORWARD rules tagged `-m comment --comment amneziawg-addon`; persist WAN+subnet to `.runtime`. `nat_down`: read `.runtime`; `-D` each tagged rule (ignore errors); restore ip_forward.
- [ ] Lint: `bash -n network.sh` and `shellcheck` if available. Expected: clean.
- [ ] Commit: `feat: NAT/forwarding setup + teardown`.

### Task 8: export.sh (files + QR)

**Files:** Create `amneziawg/rootfs/usr/lib/amneziawg/export.sh`

**Steps:**
- [ ] Write `export_clients`: `mkdir -p $EXPORT_DIR` (mode 700); for each resolved client, `render_client_conf` → `$EXPORT_DIR/<name>.conf` (600); `qrencode -t png -o <name>.png`; `qrencode -t ANSIUTF8` to log; log summary (name, ip, pubkey fingerprint, paths). Never log conf contents.
- [ ] `bash -n export.sh`. Expected: clean.
- [ ] Commit: `feat: client config + QR export`.

### Task 9: s6 service (run + finish)

**Files:** Create `amneziawg/rootfs/etc/services.d/amneziawg/run`, `.../finish`

**Steps:**
- [ ] Write `run` (`#!/usr/bin/with-contenv bashio`): source libs; populate env via `bashio::config`; build `CLIENTS_TSV` from `bashio::config 'clients'` (jq over `/data/options.json` for robust list/dict handling); `validate_all || die`; `ensure_obfuscation; ensure_server_keys; resolve_clients`; `render_server_conf`; `nat_up`; `awg-quick up "$IFACE"`; `export_clients`; log "up" banner (no secrets); watchdog `while awg show "$IFACE" >/dev/null 2>&1; do sleep "${WATCHDOG_INTERVAL:-15}" & wait $!; done; log_warn ...; exit 1`.
- [ ] Write `finish`: source common+network; `awg-quick down "$IFACE" || true`; `nat_down || true`.
- [ ] `bash -n run finish`. Expected: clean.
- [ ] Commit: `feat: s6 run/finish service with watchdog + clean teardown`.

### Task 10: apparmor profile

**Files:** Create `amneziawg/apparmor.txt`

**Steps:**
- [ ] Write profile (modeled on community WG add-on): allow s6 init, bash, the libs, `awg*`, `ip`, `iptables*`, `sysctl`, `qrencode`, rw `/data/**` and `/config/**`, `/dev/net/tun`, capability `net_admin`.
- [ ] Commit: `feat: apparmor profile`.

### Task 11: smoke test

**Files:** Create `tests/test-smoke.sh`

**Steps:**
- [ ] Write: `docker build` the add-on with `BUILD_FROM` arg; `docker run --rm --cap-add=NET_ADMIN --device=/dev/net/tun -e ...env... <img>` running an in-container script that sources libs, generates real keys (awg present), renders, `nat_up`, `awg-quick up`, asserts `awg show awg0`, `iptables -t nat -S | grep -q 'amneziawg-addon.*MASQUERADE'`, `sysctl -n net.ipv4.ip_forward` == 1, then `awg-quick down` + `nat_down` + assert tagged rules gone. Skips with a clear message if Docker unavailable.
- [ ] Commit: `test: container smoke test for iface/NAT/forward/teardown`.

### Task 12: docs

**Files:** Create `README.md` (repo), `amneziawg/README.md`, `amneziawg/DOCS.md`, `amneziawg/CHANGELOG.md`

**Steps:**
- [ ] Repo `README.md`: overview, feasibility summary, install (Samba drop / repo URL), link to DOCS.
- [ ] `amneziawg/DOCS.md`: per spec §12 — options table, router UDP port-forward + DDNS, client apps (Amnezia/awg), add a client, retrieve config/QR, verify exit via HASS, MTU/DNS/AllowedIPs/keepalive tuning, full Risks section incl. Cloudflare-won't-work.
- [ ] `amneziawg/CHANGELOG.md`: `1.0.0` initial.
- [ ] Commit: `docs: README, DOCS, CHANGELOG`.

### Task 13: build verification + final wiring

**Steps:**
- [ ] `bash tests/test-render.sh` → all PASS.
- [ ] `shellcheck` all `rootfs/usr/lib/amneziawg/*.sh` + service scripts (if available) → triage.
- [ ] If Docker available: `docker build --build-arg BUILD_FROM=ghcr.io/hassio-addons/base:19.0.0 -t awg-test amneziawg/` → success; then `bash tests/test-smoke.sh`. If Docker unavailable: record limitation in final report.
- [ ] Final commit if anything changed: `chore: build verification fixes`.

## Self-Review

- **Spec coverage:** options (Task 1) ✓; userspace build (2) ✓; validation §9 (4) ✓; idempotent keys+obfuscation §7 (5) ✓; rendering (6) ✓; NAT §8 (7) ✓; export files+QR (8) ✓; service+watchdog+teardown §8 (9) ✓; apparmor (10) ✓; tests §11 (3,4,5,6,11) ✓; docs §12 (12) ✓; acceptance §13 (13) ✓.
- **Placeholder scan:** none — each task has concrete files/commands.
- **Type/name consistency:** function names match the locked contract block across tasks.
