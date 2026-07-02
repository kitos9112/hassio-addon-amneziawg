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

Two ways to cut a release. **Method 1 (the Release workflow) is the normal path** — one
trigger does everything. Method 2 is a manual fallback.

### Method 1 — the Release workflow (recommended)

Bumps `version:` in `config.yaml`, regenerates `CHANGELOG.md` from Conventional Commits,
commits, tags `vX.Y.Z`, creates the GitHub Release, and builds + pushes the multi-arch
image to GHCR — all in one run.

- **Web GUI:** **Actions → Release → Run workflow**. Optionally set `version` (e.g.
  `1.1.0`) or tick **dry_run**; leave `version` blank to auto-bump from the Conventional
  Commits since the last tag.
- **CLI (`gh`):**

  ```bash
  gh workflow run release.yaml                    # auto-bump from Conventional Commits
  gh workflow run release.yaml -f version=1.1.0   # or pin the version
  gh workflow run release.yaml -f dry_run=true    # preview version + changelog only, no tag/publish

  # follow the run it just started:
  gh run watch "$(gh run list --workflow=release.yaml -L1 --json databaseId --jq '.[0].databaseId')"
  ```

- **First release only:** pass an explicit `version` — there is no prior tag to bump from.
- `main` branch protection must allow `github-actions[bot]` to push the release commit + tag
  (or switch the workflow to a PR-based bump).

### Method 2 — cut the GitHub Release yourself (manual fallback)

Use this when `version:` in `config.yaml` (and `CHANGELOG.md`) is **already** bumped in a
merged commit and you just want to publish it. Publishing a Release fires the **Deploy**
workflow, which builds + pushes the image.

> **Deploy reads `version:` from `config.yaml` on the tagged commit — not the tag name.**
> Make sure the commit you tag already carries the intended version, or the wrong tag gets
> published.

- **Web GUI:** **Releases → Draft a new release → choose or create the tag `vX.Y.Z` →
  Publish release.**
- **CLI (`gh`):**

  ```bash
  gh release create v1.1.0 --target main --title v1.1.0 --generate-notes
  # …or supply your own notes:  --notes-file notes.md
  ```

  (A release published via `gh`/the web UI runs as *you*, so it triggers Deploy. A release
  created by a workflow's default `GITHUB_TOKEN` would not — which is why Method 1 builds
  inline instead of relying on Deploy.)

### Rebuild / re-publish an existing version (no new release)

Run **Deploy** on demand — **Actions → Deploy → Run workflow**, or
`gh workflow run deploy.yaml`. It rebuilds + pushes the image for the `version:` currently
in `config.yaml` without creating a tag or release.

### One-time, after the very first publish

Make the GHCR package **Public**, or every user's install fails with an image-pull error:
GitHub → your profile → **Packages** → `amneziawg` → **Package settings** →
**Change visibility → Public**, then verify with
`docker pull ghcr.io/kitos9112/amneziawg:<version>`.

## Security

- **Never commit secrets** — private keys, client `.conf` files, or QR codes.
  `/data`, `**/clients/`, and `*.key` are git-ignored; keep it that way.
- Report security issues privately via a [GitHub Security Advisory](https://github.com/kitos9112/hassio-addon-amneziawg/security/advisories/new) (see [SECURITY.md](SECURITY.md)) — not a public issue.
