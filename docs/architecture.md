# Architecture

How an image is built, what each stage may touch, and where the state of a build lives. How a
build reaches a host is [`workflow.md`](workflow.md); why each feature exists is
[`divergences.md`](divergences.md).

Contents: build flow · `.github/scripts/` · `build_files/` · `system_files/` · state of a build ·
gates, in order.

## Build flow

```
Containerfile
  ctx           FROM scratch, COPY build_files, system_files, cosign.pub   bound at /ctx, never in the image
  kmod-builder  FROM ${BASE_IMAGE}: build_files/kmods/build-kmods.sh --self-test, then the build:
                  BTF prepared (vmlinux extracted, pahole built from the kernel's tag), each module → /out/<kver>/updates/*.ko
  image         FROM ${BASE_IMAGE}
    RUN /ctx/build_files/build.sh                  mounts: /kmods (from kmod-builder), /var/cache and /var/log (cache), /run and /tmp (tmpfs)
    RUN /ctx/build_files/tests/run.sh              offline; tmpfs on /run, /tmp, /var/log, /var/cache
    RUN rpm -V --nomtime python3-setuptools && bootc container lint …    offline; tmpfs on /run
```

The base image builds the kernel modules itself, so there is no akmods carrier stage. The
staged modules are bound at `/kmods`, a root-level mount point buildah removes after the RUN;
why that path and why `/run` is a tmpfs is on the `RUN` itself in the `Containerfile`.

`BASE_IMAGE` and `IMAGE_NAME` are the two variables between the three flavours, both mapped
from the flavour by `resolve-base.sh`, and `VERSION` is the version the image calls itself: the
release tag, or `<base version>.dev` for a sandbox or pre-flight build. CI and `/preflight`
resolve the base to a digest with `.github/scripts/resolve-base.sh`, which also reads the
base's kernel from its `ostree.linux` label. They take `VERSION` and every `--label` from
`.github/scripts/image-labels.sh`; `10-image-info.sh` repeats the `.dev` rule for a
`podman build` by hand with no `VERSION`.

## .github/scripts/

Each script owns one artefact and ships a `--self-test`.

| Script                                            | Role                                                                                                                                                                                                                                                 |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lib.sh`                                          | coordinates, `exit_with_error`/`print_error`, `require_option_value`, `emit`, `read_env`, `image_of`, `absent_error`, `TAG_SHAPE`, `fail_self_test`; sourced by all but `check-form.sh` and `check-commits.sh`                                       |
| `resolve-base.sh <flavour> \| --digests`          | the base's digest, version and kernel, and the image name; the three digests keyed by flavour                                                                                                                                                        |
| `image-labels.sh <coords> <tag> <rev>`            | the labels file; the coordinates as `resolve-base.sh` wrote them                                                                                                                                                                                     |
| `check-image.sh <image> <labels>`                 | the probe of a built image: labels, `/run` and `/tmp`, lint, packages, modules, the ntfsplus opt-in, `image-info.json`                                                                                                                               |
| `release-tag.sh <coords> \| --tag <tag> <coords>` | the release tag, `.N` only when the tag is taken; a forced tag, refused when malformed, on another Fedora or taken                                                                                                                                   |
| `gate-release.sh release\|promote`                | verify by digest, write `:<tag>`, promote `:stable`                                                                                                                                                                                                  |
| `changelog.sh release`                            | the release notes and the release title                                                                                                                                                                                                              |
| `install-oras.sh <version> <dir>`                 | the ORAS CLI, tarball refused on a checksum mismatch                                                                                                                                                                                                 |
| `refresh-pins.sh`                                 | the pin table (`--check`) and the rewrite (`--apply`)                                                                                                                                                                                                |
| `check-commits.sh [<rev>]`                        | the commit-message rules (§ Commits of `conventions.md`) over every commit reachable from `<rev>`                                                                                                                                                    |
| `check-form.sh <file>...`                         | the form rules (§ Bash → Form of `conventions.md`): line width, the banned control-flow shapes and the four failure shapes (`\| grep -q`, `\|\| echo` fallback, a pipeline assigned without `\|\| true`, a `$( )` inside `$(( ))`), on logical lines |
| `preflight-build.sh [<flavour>] [--no-cache]`     | the local pre-flight: base, labels, build, log judged on the scripts' own output, probe                                                                                                                                                              |
| `watch-upstream.sh check\|decide`                 | the base-digest verdict, and whether to dispatch                                                                                                                                                                                                     |

## build_files/

| Path                      | Role                                                                                                                                             |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `build.sh`                | runs `NN-<feature>.sh` in version order, one group each, stops at the first failure                                                              |
| `lib/env.sh`              | sourced first: `CTX`, `BUILD_FILES`, `BUILD_TMP`, `BUILD_STATE`, `PYTHONDONTWRITEBYTECODE`, then every library but `kmod.sh`                     |
| `lib/log.sh`              | `group`, `endgroup`, `log`, `fail_build`                                                                                                         |
| `lib/repos.sh`            | `install_from_repo`, `enabled_repos`                                                                                                             |
| `lib/flatpak.sh`          | `deny_flatpak <ref>`: one deny line in the base's Flatpak filter                                                                                 |
| `lib/just.sh`             | `recipe_set`, `has_recipe`; output captured before any grep                                                                                      |
| `lib/kmod.sh`             | `kernel_version`, `assert_module`; shared with the kmod-builder stage                                                                            |
| `lib/gpg.sh`              | the `KEY_FPR` table, `key_fingerprint` and `assert_key_fingerprint`                                                                              |
| `kmods/build-kmods.sh`    | the kmod-builder stage: BTF prepared (vmlinux extracted, pahole built from the kernel's tag), then per module fetch, build, strip, stage, assert |
| `kmods/<name>/source.env` | one module: URL, pinned commit, object path, build arguments                                                                                     |
| `00-prep.sh`              | dnf keeps its cache and waits 60 s against COPR and mirror flakes; the base's repositories, recipe sets and module dependencies are recorded     |
| `01-system-files.sh`      | `rsync` of `system_files/` over the tree, every file on a fresh inode; the fixed-gid groups                                                      |
| `10-image-info.sh`        | identity: `image-info.json`, os-release, the KDE About page                                                                                      |
| `11-image-signing.sh`     | the public key and the `policy.json` scope for `ghcr.io/matrixdj96`                                                                              |
| `20-setup-services.sh`    | the `ublue-setup-services` hook framework and its system unit                                                                                    |
| `21-container-runtime.sh` | Docker CE, the podman tools, both sockets enabled                                                                                                |
| `22-virtualization.sh`    | libvirt, QEMU/KVM, virt-manager, swtpm, quickemu                                                                                                 |
| `30-ide.sh`               | Visual Studio Code and the per-user extensions hook                                                                                              |
| `31-git-tools.sh`         | GitKraken and git-credential-libsecret                                                                                                           |
| `32-cli-rpms.sh`          | the Fedora command-line and system-administration packages                                                                                       |
| `33-mise.sh`              | mise from its COPR; activation and defaults come from `system_files/`                                                                            |
| `40-desktop-apps.sh`      | Firefox, gparted, 1Password, and the Firefox Flatpak denied                                                                                      |
| `41-sunshine.sh`          | Sunshine from its COPR, its user unit left disabled, its menu entry routed to the recipe                                                         |
| `45-kde-defaults.sh`      | the Plasma update scripts, the skel files and their login hook                                                                                   |
| `50-kmods.sh`             | installs the staged modules under `updates/`, runs depmod, asserts each                                                                          |
| `55-ntfsplus.sh`          | NTFSPLUS as an opt-in: the blacklist, the mount helpers, the alias                                                                               |
| `70-justfile.sh`          | the ujust recipes: drift guard, overrides, import, format check                                                                                  |
| `80-fix-opt.sh`           | `/var/opt/<name>` moves to `/usr/lib/opt/<name>` with a tmpfiles line                                                                            |
| `90-validate-repos.sh`    | the repository gate, run after the last install                                                                                                  |
| `95-clean-stage.sh`       | the tree bootc lint and the rechunk expect                                                                                                       |
| `tests/run.sh`            | the test runner and the pairing guard                                                                                                            |
| `tests/lib.sh`            | the checks the tests share, one `OK:`/`FAIL:` line each                                                                                          |
| `tests/NN-<feature>.sh`   | one smoke test per build script, same stem                                                                                                       |
| `tests/helpers/<name>.sh` | the fixture cases of `usr/libexec/bazzite-mx-<name>`                                                                                             |

Numbering, as the tree uses it: `00-09` preparation, `10-19` identity and trust, `20-49`
services, packages and desktop defaults, `50-59` kernel modules, `70-79` justfile, `80-89`
fix-ups, `90-99` gates and cleanup. The file name is the only statement of the order.

## system_files/

One tree, copied over `/` by `01-system-files.sh`.

| Path                                           | Content                                                                                                                                                                                                                                                                                                                    |
| ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `etc/yum.repos.d/`                             | the five vendored repositories, every section `enabled=0`                                                                                                                                                                                                                                                                  |
| `etc/pki/rpm-gpg/RPM-GPG-KEY-*`                | the five keys those files read with `gpgkey=file://`                                                                                                                                                                                                                                                                       |
| `etc/containers/registries.d/matrixdj96.yaml`  | sigstore attachments for our own scope                                                                                                                                                                                                                                                                                     |
| `etc/profile.d/mise.sh`                        | activation, in bash only                                                                                                                                                                                                                                                                                                   |
| `etc/skel/`                                    | per-user defaults: VS Code, mise, PowerShell, the Konsole shortcuts                                                                                                                                                                                                                                                        |
| `etc/udisks2/mount_options.conf`               | udisks' `ntfs` driver options with `errors=remount-ro`                                                                                                                                                                                                                                                                     |
| `usr/lib/bazzite-mx/host.sh`                   | what `verify-host`, `migrate`, `ntfsplus-setup` and `msi-setup` read about the host (`host_file`, the sources, the fstab field unescaping, the residue lists, the MSI modules-load path), the fstab type rewrite and the verification `migrate` and `ntfsplus-setup` judge it on, and `exit_with_error` and `require_root` |
| `usr/lib/modprobe.d/bazzite-mx-*.conf`         | the KVM options and the NTFSPLUS blacklist                                                                                                                                                                                                                                                                                 |
| `usr/lib/modules-load.d/ip_tables.conf`        | `iptable_nat`, which docker-in-docker needs                                                                                                                                                                                                                                                                                |
| `usr/lib/sysusers.d/bazzite-mx-groups.conf`    | the fixed gids of `docker` and `libvirt`                                                                                                                                                                                                                                                                                   |
| `usr/lib/systemd/system/docker.service.d/`     | the drop-in that runs the libvirt forwarding helper once dockerd is ready                                                                                                                                                                                                                                                  |
| `usr/lib/tmpfiles.d/bazzite-mx-virt.conf`      | the `/var` directories libvirt and swtpm need                                                                                                                                                                                                                                                                              |
| `usr/libexec/`                                 | the helpers the recipes and `docker.service` call; ours take a fixture knob for their test                                                                                                                                                                                                                                 |
| `usr/share/ublue-os/just/`                     | two files replacing a base file, and `95-bazzite-mx.just`                                                                                                                                                                                                                                                                  |
| `usr/share/plasma/.../updates/bazzite-mx-*.js` | Plasma update scripts, one run per user                                                                                                                                                                                                                                                                                    |
| `usr/share/ublue-os/system-setup.hooks.d/`     | the root hook that grants the service groups and moves their gids to the image's                                                                                                                                                                                                                                           |
| `usr/share/ublue-os/user-setup.hooks.d/`       | the per-user hooks: VS Code and the two skel files                                                                                                                                                                                                                                                                         |

## State of a build

| Where                                              | Lifetime                       | Content                                                       |
| -------------------------------------------------- | ------------------------------ | ------------------------------------------------------------- |
| `/tmp/bazzite-mx-build/` (`BUILD_TMP`)             | the build `RUN` (tmpfs)        | backups a later script restores                               |
| `/usr/lib/bazzite-mx/build-state/` (`BUILD_STATE`) | shipped in the image           | the base's repository, recipe and module-dependency snapshots |
| `/var/cache`, `/var/log`                           | cache mounts, not in the image | the dnf cache and logs                                        |

## Gates, in order

1. `90-validate-repos.sh` after the last install: the image ships no enabled third-party
   repository, the enabled set read from `dnf5 repolist` itself, and no modified base
   repository.
2. `tests/run.sh`: every feature's smoke test on the cleaned tree, offline.
3. `rpm -V --nomtime python3-setuptools`, then `bootc container lint --fatal-warnings`: the
   last word, offline; `rpm -V` sees a packaged `.pyc` the build or the test RUN rewrote
   ([`gotchas.md`](gotchas.md) § A scriptlet rewrote a packaged `.pyc`).

Every gate is proven on a known-bad input before it counts ([`conventions.md`](conventions.md)
§ Positive control).
