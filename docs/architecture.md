# Architecture

How an image is built, what each stage may touch, and where the state of a build lives. How a
build reaches a host is [`workflow.md`](workflow.md); why each feature exists is
[`divergences.md`](divergences.md).

## Build flow

```
Containerfile
  ctx           FROM scratch, COPY build_files, system_files, cosign.pub   bound at /ctx, never in the image
  kmod-builder  FROM ${BASE_IMAGE}: build_files/kmods/build-kmods.sh --self-test, then the build → /out/<kver>/updates/*.ko
  image         FROM ${BASE_IMAGE}
    RUN /ctx/build_files/build.sh                  mounts: /kmods (from kmod-builder), /var/cache and /var/log (cache), /run and /tmp (tmpfs)
    RUN /ctx/build_files/tests/run.sh              offline; tmpfs on /run, /tmp, /var/log, /var/cache
    RUN bootc container lint --fatal-warnings --no-truncate    offline; tmpfs on /run
```

The base image builds the kernel modules itself: it ships `kernel-devel` for its own kernel and
the toolchain, so there is no akmods carrier stage. The staged modules are bound at `/kmods`, a
root-level mount point buildah removes after the RUN. A stage mount under `/tmp`, `/var` or
`/run` would make clean-stage's `find -delete` fail on the read-only bind. `/run` is a tmpfs
for a related reason: buildah binds the host's resolv.conf under it for the network, and
without the tmpfs that path stays in the image.

`BASE_IMAGE` is the only variable between the three flavours. `IMAGE_NAME` follows it
(`resolve-base.sh` prints both) and `VERSION` is the version the image calls itself: the
release tag, or `<base version>.dev` for a sandbox or pre-flight build. CI and `/preflight`
resolve the base to a digest with `.github/scripts/resolve-base.sh`, which also reads the
base's kernel from its `ostree.linux` label. They take `VERSION` and every `--label` from
`.github/scripts/image-labels.sh`; `10-image-info.sh` repeats the `.dev` rule for a
`podman build` by hand with no `VERSION`.

## .github/scripts/

Each script owns one artefact and ships a `--self-test`.

| Script | Role |
|---|---|
| `lib.sh` | coordinates, `fail`/`err`, `emit`, `read_env`, `image_of`, `TAG_SHAPE`; sourced by all |
| `resolve-base.sh <flavour> \| --digests` | the base's digest, version and kernel, and the image name; the three digests keyed by flavour |
| `image-labels.sh <coords> <tag> <rev>` | the labels file, every value required |
| `check-image.sh <image> <labels>` | the probe of a built image: labels, lint, packages, modules |
| `release-tag.sh <coords>` | the release tag, `.N` only when the tag is taken |
| `gate-release.sh release\|promote` | verify by digest, write `:<tag>`, promote `:stable` |
| `changelog.sh release` | the release notes and the release title |
| `install-oras.sh <version> <dir>` | the ORAS CLI, tarball refused on a checksum mismatch |
| `refresh-pins.sh` | the pin table (`--check`) and the rewrite (`--apply`) |
| `check-site.sh <dir>` | the site, page by page, links included |
| `preflight-build.sh <flavour> [--no-cache]` | the local pre-flight: base, labels, build, log judged on the scripts' own output, probe |
| `watch-upstream.sh check\|decide` | the base-digest verdict, and whether to dispatch |

## build_files/

| Path | Role |
|---|---|
| `build.sh` | runs `NN-<feature>.sh` in version order, one group each, stops at the first failure |
| `lib/env.sh` | sourced first: `CTX`, `BUILD_FILES`, `BUILD_TMP`, `BUILD_STATE`, then the other libraries |
| `lib/log.sh` | `group`, `endgroup`, `log`, `die` |
| `lib/repos.sh` | `install_from_repo`, `copr_install_isolated` |
| `lib/flatpak.sh` | `deny_flatpak <ref>`: one deny line in the base's Flatpak filter |
| `lib/just.sh` | `recipe_set`, `has_recipe`; output captured before any grep |
| `lib/kmod.sh` | `kernel_version`, `assert_module`; shared with the kmod-builder stage |
| `lib/gpg.sh` | the `KEY_FPR` table and `assert_key_fingerprint` |
| `kmods/build-kmods.sh` | the kmod-builder stage: fetch, build, strip, stage, assert |
| `kmods/<name>/source.env` | one module: URL, pinned commit, object path, build arguments |
| `00-prep.sh` | dnf keeps its cache; the base's repository and recipe sets are recorded |
| `01-system-files.sh` | `rsync` of `system_files/` over the tree, every file on a fresh inode |
| `10-image-info.sh` | identity: `image-info.json`, os-release, the KDE About page |
| `11-image-signing.sh` | the public key and the `policy.json` scope for `ghcr.io/matrixdj96` |
| `20-setup-services.sh` | the `ublue-setup-services` hook framework and its system unit |
| `21-container-runtime.sh` | Docker CE, the podman tools, both sockets enabled |
| `22-virtualization.sh` | libvirt, QEMU/KVM, virt-manager, swtpm, quickemu |
| `30-ide.sh` | Visual Studio Code and the per-user extensions hook |
| `31-git-tools.sh` | GitKraken and git-credential-libsecret |
| `32-cli-rpms.sh` | the Fedora command-line and system-administration packages |
| `33-mise.sh` | mise from its COPR; activation and defaults come from `system_files/` |
| `40-desktop-apps.sh` | Firefox, gparted, 1Password, and the Firefox Flatpak denied |
| `41-sunshine.sh` | Sunshine from its COPR, its user unit left disabled |
| `45-kde-defaults.sh` | the Plasma update scripts and the skel files that carry KDE defaults |
| `50-kmods.sh` | installs the staged modules under `updates/`, runs depmod, asserts each |
| `55-ntfsplus.sh` | NTFSPLUS as an opt-in: the blacklist, the mount helpers, the alias |
| `70-justfile.sh` | the ujust recipes: drift guard, overrides, import, format check |
| `80-fix-opt.sh` | `/var/opt/<name>` moves to `/usr/lib/opt/<name>` with a tmpfiles line |
| `90-validate-repos.sh` | the repository gate, run after the last install |
| `95-clean-stage.sh` | the tree bootc lint and the rechunk expect |
| `tests/run.sh` | the test runner and the pairing guard |
| `tests/lib.sh` | the checks the tests share, one `OK:`/`FAIL:` line each |
| `tests/NN-<feature>.sh` | one smoke test per build script, same stem |

Numbering, as the tree uses it: `00-09` preparation, `10-19` identity and trust, `20-49`
services, packages and desktop defaults, `50-59` kernel modules, `70-79` justfile, `80-89`
fix-ups, `90-99` gates and cleanup. The file name is the only statement of the order.

## system_files/

One tree, copied over `/` by `01-system-files.sh`.

| Path | Content |
|---|---|
| `etc/yum.repos.d/` | the five vendored repositories, every section `enabled=0` |
| `etc/pki/rpm-gpg/RPM-GPG-KEY-*` | the five keys those files read with `gpgkey=file://` |
| `etc/containers/registries.d/matrixdj96.yaml` | sigstore attachments for our own scope |
| `etc/profile.d/mise.sh` | shell activation, guarded on the binary |
| `etc/skel/` | per-user defaults: VS Code, mise, PowerShell, the Konsole shortcuts |
| `usr/lib/bazzite-mx/host.sh` | what `verify-host` and `migrate` both read about the host |
| `usr/lib/modprobe.d/bazzite-mx-*.conf` | the KVM options and the NTFSPLUS blacklist |
| `usr/lib/modules-load.d/ip_tables.conf` | `iptable_nat`, which docker-in-docker needs |
| `usr/lib/tmpfiles.d/bazzite-mx-virt.conf` | the `/var` directories libvirt and swtpm need |
| `usr/libexec/` | the helpers the recipes call; ours take a fixture knob for their test |
| `usr/share/ublue-os/just/` | two files replacing a base file, and `95-bazzite-mx.just` |
| `usr/share/plasma/.../updates/bazzite-mx-*.js` | Plasma update scripts, one run per user |
| `usr/share/ublue-os/system-setup.hooks.d/` | the root hook that grants the service groups |
| `usr/share/ublue-os/user-setup.hooks.d/` | the per-user hook that seeds VS Code |

## State of a build

| Where | Lifetime | Content |
|---|---|---|
| `/tmp/bazzite-mx-build/` (`BUILD_TMP`) | the build `RUN` (tmpfs) | backups a later script restores |
| `/usr/lib/bazzite-mx/build-state/` (`BUILD_STATE`) | shipped in the image | the base's repository and recipe snapshots |
| `/var/cache`, `/var/log` | cache mounts, not in the image | the dnf cache and logs |

## Gates, in order

1. `90-validate-repos.sh` after the last install: the image ships no enabled third-party
   repository and no modified base repository.
2. `tests/run.sh`: every feature's smoke test on the cleaned tree, offline.
3. `bootc container lint --fatal-warnings`: the last word, offline.

Every gate is proven on a known-bad input before it counts ([`conventions.md`](conventions.md)
§ Positive control).
