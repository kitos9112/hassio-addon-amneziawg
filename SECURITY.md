# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue.

- Preferred: open a private
  [GitHub Security Advisory](https://github.com/kitos9112/hassio-addon-amneziawg/security/advisories/new).
- Expect an acknowledgement within a few days; a fix and coordinated disclosure
  will follow.

When reporting, **never include private keys, client `.conf` contents, or QR
codes** — redact them.

## Supported versions

This is a community project; security fixes target the latest released version.
Please run the newest tag.

## Scope notes

This add-on runs a VPN exit node and therefore uses `host_network`,
`CAP_NET_ADMIN`, and `/dev/net/tun`. It generates and stores WireGuard private
keys under `/data` (mode `600`) and exports client configs — which contain client
private keys — to the add-on's config share. Treat exported `.conf`/QR codes as
secrets.
