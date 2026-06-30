# Contributing

Thanks for your interest in improving the AmneziaWG Server add-on!

## Development

The add-on is small, auditable shell on top of the userspace `amneziawg-go`
implementation. Key paths:

- `amneziawg/config.yaml` — options + schema (the add-on UI).
- `amneziawg/Dockerfile` — multi-stage build of `amneziawg-go` + `amneziawg-tools`.
- `amneziawg/rootfs/usr/lib/amneziawg/*.sh` — the logic (validate / keys / render / network / export).
- `amneziawg/rootfs/etc/services.d/amneziawg/{run,finish}` — the s6 service.

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

## Releasing

Releases are automated by the **Release** workflow (Actions → Release → Run workflow):
it bumps `version:` in `config.yaml`, regenerates `CHANGELOG.md` from Conventional
Commits, tags `vX.Y.Z`, creates the GitHub Release, and builds + pushes the multi-arch
image to GHCR.

- **First release only:** pass an explicit `version` (e.g. `1.0.0`) — there is no prior
  tag to auto-bump from. Later releases can leave it blank.
- **One-time, after the first publish:** make the GHCR package **Public**, or every
  user's install fails with an image-pull error. GitHub → your profile → **Packages** →
  `amneziawg` → **Package settings** → **Change visibility → Public**, then verify with
  `docker pull ghcr.io/kitos9112/amneziawg:<version>`.
- `main` branch protection must allow `github-actions[bot]` to push the release
  commit/tag (or switch the workflow to a PR-based bump).

## Security

- **Never commit secrets** — private keys, client `.conf` files, or QR codes.
  `/data`, `**/clients/`, and `*.key` are git-ignored; keep it that way.
- Report security issues privately via a [GitHub Security Advisory](https://github.com/kitos9112/hassio-addon-amneziawg/security/advisories/new) (see [SECURITY.md](SECURITY.md)) — not a public issue.
