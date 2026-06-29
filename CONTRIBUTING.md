# Contributing

Thanks for your interest in improving the AmneziaWG Server add-on!

## Development

The add-on is small, auditable shell on top of the userspace `amneziawg-go`
implementation. Key paths:

- `amneziawg/config.yaml` — options + schema (the add-on UI).
- `amneziawg/Dockerfile` — multi-stage build of `amneziawg-go` + `amneziawg-tools`.
- `amneziawg/rootfs/usr/lib/amneziawg/*.sh` — the logic (validate / keys / render / network / export).
- `amneziawg/rootfs/etc/services.d/amneziawg/{run,finish}` — the s6 service.
- `docs/superpowers/` — design spec + implementation plan.

## Tests

```bash
# Pure-logic suite (no root): validation, key generation, rendering, export.
bash tests/test-render.sh

# Integration: builds the image and brings the interface up in a container.
# Needs docker or podman; the live awg-quick step runs only where /dev/net/tun exists.
bash tests/test-smoke.sh            # or: CONTAINER_ENGINE=podman bash tests/test-smoke.sh
```

## Linting (matches CI)

```bash
shellcheck -s bash -e SC1090,SC1091,SC2016 \
  amneziawg/rootfs/usr/lib/amneziawg/*.sh \
  amneziawg/rootfs/etc/services.d/amneziawg/run \
  amneziawg/rootfs/etc/services.d/amneziawg/finish \
  tests/*.sh
# hadolint amneziawg/Dockerfile      # Dockerfile
# yamllint .                          # YAML
```

## Pull requests

- Keep changes focused; update `amneziawg/DOCS.md` and `amneziawg/CHANGELOG.md`
  when behaviour or options change.
- Bump `version:` in `amneziawg/config.yaml` for releases — it must match the
  published image tag.
- CI (lint + unit + container smoke) must pass.

## Security

- **Never commit secrets** — private keys, client `.conf` files, or QR codes.
  `/data`, `**/clients/`, and `*.key` are git-ignored; keep it that way.
- Report security issues privately to the maintainer rather than in a public issue.
