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
    build-mx.sh        # runs sysctl + iptable_nat module + numbered mx/*.sh
    copr-helpers.sh    # copr_install_isolated() (port from Aurora)
    clean-stage.sh     # selective /var cleanup (no rm -rf /var)
    validate-repos.sh  # fail build if any third-party repo enabled=1
  mx/                  # numbered scripts per build domain (image-info, container, virt, IDE, …)
  tests/
    10-tests-mx.sh     # smoke tests (rpm-q + systemctl is-enabled, bloccante)
system_files/          # copied 1:1 to / by build.sh
Containerfile          # parametrized via build args (BASE_IMAGE/BASE_TAG/IMAGE_NAME/IMAGE_VENDOR)
.github/workflows/
  reusable-build.yml   # matrix build of the 3 variants for one stream
  build-stable.yml     # push:main + PR + dispatch -> reusable(stable)
  build-testing.yml    # push:main + PR + dispatch -> reusable(testing)
  watch-upstream.yml   # cron hourly: detect new upstream releases, rebuild only the changed stream
cosign.pub             # public key used to verify signed images
docs/superpowers/      # implementation plan + validation notes
```

**Architecture:** `bazzite-mx` is a single-flavour distribution. The numbered `build_files/mx/*.sh` scripts (Aurora-DX-style: image-info branding, container runtime, virtualization, dev tools, ujust install-* recipes) all run unconditionally. The three GHCR variants differ only in `BASE_IMAGE`.

## Building locally

Pre-flight a single flavour before pushing to CI (~5 min on a recent laptop, vs ~15 min for the full 6-job CI matrix):

```bash
podman build --file Containerfile \
  --build-arg BASE_IMAGE=bazzite \
  --build-arg BASE_TAG=$(skopeo inspect --no-tags \
      docker://ghcr.io/ublue-os/bazzite:stable \
      | jq -r '.Labels["org.opencontainers.image.version"]') \
  --build-arg IMAGE_NAME=bazzite-mx \
  --build-arg IMAGE_VENDOR=matrixdj96 \
  --tag localhost/bazzite-mx:preflight .
```

Swap `BASE_IMAGE` to `bazzite-nvidia` or `bazzite-nvidia-open` and `IMAGE_NAME` to the matching `bazzite-mx-{nvidia,nvidia-open}` to pre-flight the other variants.

Smoke tests (`build_files/tests/10-tests-mx.sh`) run as a blocking step inside the build — a failed assertion fails the build. Authoritative conventions, gotchas, and the per-phase build-domain layout live under [`.claude/docs/`](.claude/docs/).

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
