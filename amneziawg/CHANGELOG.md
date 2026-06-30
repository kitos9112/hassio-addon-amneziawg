# Changelog

All notable changes to the AmneziaWG Server add-on are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

## 1.1.0 - 2026-06-30

### Added

- **Key export / import via the Configuration GUI.** Paste a server or per-client
  private/preshared key to import it (used for empty slots unless
  `key_import.overwrite` is set). One-shot `key_export.enabled` writes individual
  key files plus a portable bundle (`amneziawg-backup.awg`) to the add-on config
  share; one-shot `key_import.restore` imports keys from `amneziawg-restore.awg`.
- **Optional bundle encryption** with a passphrase (AES-256, PBKDF2); encrypted
  bundles are auto-detected on import.

### Changed

- Client and server key generation is now per-file idempotent, so importing a
  subset of a key set (e.g. only a private key) preserves and completes the rest.
- The runtime image now includes `openssl` (bundle encryption).

## 1.0.0 - 2026-06-29

Initial release.

### Added

- AmneziaWG VPN **exit node** running the userspace `amneziawg-go` +
  `amneziawg-tools` (no kernel module). Builds for `amd64` and `aarch64`.
- Idempotent server + per-client key generation, persisted in `/data`
  (restarts never rotate keys unless `regenerate_clients` is set).
- AmneziaWG obfuscation (on by default; `Jc/Jmin/Jmax/S1/S2/H1–H4`
  auto-generated, persisted, and shared between server and client configs).
  Disable for plain-WireGuard compatibility.
- Declarative `clients` list with optional fixed addresses and per-client
  `allowed_ips`; automatic sequential IP assignment.
- Client config + QR export to `/addon_configs/local_amneziawg/clients/`, plus
  optional scannable QR in the add-on log (`qr_in_log`).
- IPv4 forwarding + NAT/masquerade with tagged firewall rules and clean
  teardown on stop/crash via the s6 `finish` script.
- Configurable UDP port (default `51820`, sub-1024 supported), subnet, DNS,
  MTU, AllowedIPs, persistent keepalive, and NAT toggle.
- Configuration validation (CIDRs, duplicate clients, address bounds,
  obfuscation constraints, `/dev/net/tun` presence).
- Pure-logic test suite (`tests/test-render.sh`) and container smoke test
  (`tests/test-smoke.sh`).
- AppArmor profile.

### Notes

- Pins: `amneziawg-go` `v0.2.19`, `amneziawg-tools` `v1.0.20260618-2`,
  base image `ghcr.io/hassio-addons/base:19.0.0`.
- Cloudflare Tunnel cannot carry the VPN (UDP); use a router port-forward + DDNS
  or a VPS UDP relay. See `DOCS.md`.
