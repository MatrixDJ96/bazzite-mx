# bazzite-mx

Personal [Bazzite](https://github.com/ublue-os/bazzite) customization by **matrixdj96**, built on top of the official Universal Blue Bazzite images.

## Variants

| Image | Base |
|-------|------|
| `ghcr.io/matrixdj96/bazzite-mx` | `ghcr.io/ublue-os/bazzite` |
| `ghcr.io/matrixdj96/bazzite-mx-nvidia` | `ghcr.io/ublue-os/bazzite-nvidia` |
| `ghcr.io/matrixdj96/bazzite-mx-nvidia-open` | `ghcr.io/ublue-os/bazzite-nvidia-open` |

Each variant is published with two stream tags: `:stable` and `:testing`.

## Repository layout

```
build_files/
  shared/
    build.sh           # top-level orchestrator (called from Containerfile)
    build-dx.sh        # DX overlay: sysctl, branding, runs dx/*.sh
    copr-helpers.sh    # copr_install_isolated() (port from Aurora)
    clean-stage.sh     # selective /var cleanup (no rm -rf /var)
    validate-repos.sh  # fail build if any third-party repo enabled=1
  dx/                  # numbered scripts per DX domain (container, virt, IDE, ...)
  tests/
    10-tests-dx.sh     # smoke tests (rpm-q + systemctl is-enabled, bloccante)
system_files/          # copied 1:1 to / by build.sh
Containerfile          # parametrized via build args (BASE_IMAGE/BASE_TAG/...)
.github/workflows/
  reusable-build.yml   # matrix build of the 3 variants for one stream
  build-stable.yml     # push:main + PR + dispatch -> reusable(stable)
  build-testing.yml    # push:main + PR + dispatch -> reusable(testing)
  watch-upstream.yml   # cron hourly: detect new upstream releases, rebuild only the changed stream
cosign.pub             # public key used to verify signed images
docs/superpowers/      # implementation plan + validation notes
```

**Architecture:** `bazzite-mx` is a single-flavour distribution: MX = Bazzite + DX overlay (Aurora-DX-style: container runtime, virtualization, dev tools). The three GHCR variants differ only in `BASE_IMAGE`; the build pipeline is identical.

## Image signing

All published images are signed with `cosign` using the keypair stored in this repo (`cosign.pub`) and in the `SIGNING_SECRET` repository secret.

To verify an image:

```bash
cosign verify --key cosign.pub ghcr.io/matrixdj96/bazzite-mx:stable
```

## Upstream watcher

`watch-upstream.yml` runs every hour and:

1. Fetches the latest GitHub Releases from `ublue-os/bazzite`:
   - the latest `Latest` release (stable)
   - the most recent `Pre-release` whose tag starts with `testing-`
2. Reads the `org.opencontainers.image.base.name` label from the currently published `bazzite-mx:{stable,testing}` images on GHCR.
3. For each stream where the upstream tag differs from the published label, dispatches `reusable-build.yml` pinned to the immutable upstream tag.

This makes builds reproducible (always pinned to a specific upstream release) and avoids unnecessary rebuilds.

## License

Apache-2.0 (inherited from upstream `image-template`).
