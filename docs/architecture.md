# Architecture

How an image is built, what each stage may touch, and where the state of a build lives.

## Build flow

```
Containerfile
  ctx      FROM scratch, COPY build_files, system_files, cosign.pub   never part of the image, bound at /ctx
  image    FROM ${BASE_IMAGE}
    RUN /ctx/build_files/build.sh                    mounts: /var/cache, /var/log (cache), /tmp (tmpfs)
    RUN /ctx/build_files/tests/run.sh                offline; tmpfs on /run and /tmp
    RUN bootc container lint --fatal-warnings        offline; tmpfs on /run
```

`BASE_IMAGE` is the only variable between the two flavours; `IMAGE_NAME` follows it (`resolve-base.sh` prints both) and `VERSION` is the release tag, empty for sandbox and pre-flight builds (the image then calls itself `<base version>.dev`). CI and `/preflight` resolve it to a
digest with `.github/scripts/resolve-base.sh`, which also reads the base's kernel from its
`ostree.linux` label (the akmods carrier is picked by that kernel).

## build_files/

| Path | Role |
|---|---|
| `build.sh` | orchestrator: runs `NN-<feature>.sh` in version order, one `::group::` each, stops at the first failure (bazzite-dx `build_files/build.sh:13-27`) |
| `lib/env.sh` | sourced first by every script: `CTX`, `BUILD_FILES`, `BUILD_TMP`, `BUILD_STATE`, then `log.sh` and `repos.sh` |
| `lib/log.sh` | `group`, `endgroup`, `log`, `die` |
| `lib/repos.sh` | `install_from_repo <id> <pkg>..` (vendored `.repo`, enabled for one transaction), `copr_install_isolated <owner/project> <pkg>..` (aurora `copr-helpers.sh:4-23`) |
| `lib/gpg.sh` | `key_fingerprint <file>`, `assert_key_fingerprint <file> <fpr>`: the vendored key's fingerprint against the value pinned in the feature script, before the install that trusts it |
| `00-prep.sh` | dnf keeps its cache during the build (aurora `build-prep.sh:8-9`); records the base's `.repo` files by checksum |
| `01-system-files.sh` | `rsync -rlpvK` of `system_files/` over the tree: every file lands on a fresh inode with the mode git stores |
| `10-image-info.sh` | identity: `image-info.json` (name, vendor, signed `image-ref`, `version`, `base-version`), os-release `VARIANT_ID`/`IMAGE_ID`, KDE About page (bazzite-dx `00-image-info.sh` form) |
| `11-image-signing.sh` | `cosign.pub` → `/etc/pki/containers/matrixdj96.pub`; `policy.json` scope `ghcr.io/matrixdj96` = `sigstoreSigned` + `matchRepository` (written with jq to a new file, then renamed) |
| `20-setup-services.sh` | hook framework `ublue-setup-services` (COPR `ublue-os/packages`): `ublue-system-setup.service` runs `system_files/usr/share/ublue-os/system-setup.hooks.d/*` as root at boot, before user sessions; the user unit is enabled by its first consumer |
| `21-container-runtime.sh` | Docker CE (five packages, vendored stable repo, key asserted), podman-compose/machine/tui and bcvk from Fedora, `docker.socket` + `podman.socket` enabled; the `docker` group the %post creates is relocated by clean-stage and granted to wheel users at boot by the hook `10-bazzite-mx-groups.sh` |
| `90-validate-repos.sh` | repository gate: vendored files present, identical and disabled; base files untouched; additions disabled; `--self-test` |
| `95-clean-stage.sh` | dnf.conf restored, dnf history removed, accounts relocated to `/usr/lib`, rpmdb hardlinked, `/var` `/run` `/tmp` `/boot` swept (aurora `clean-stage.sh`, bazzite `finalize`, `cleanup`) |
| `tests/run.sh` | test runner: pairing guard (every `NN-x.sh` has `tests/NN-x.sh` and vice versa), `OK:`/`FAIL:` protocol, `--self-test` |
| `tests/lib.sh` | the checks the tests share, one `OK:`/`FAIL:` line each: `check_pkg`, `check_unit_state [--global]`, `check_desktop_file`, `check_just_fmt`, `check_recipe_help`; brings `lib/just.sh` |
| `tests/NN-x.sh` | one smoke test per build script, same stem |

Numbering: `00-09` preparation, `10-19` identity and trust, `20-49` package installation,
`50-59` kernel modules, `60-69` services, `70-79` justfile, `80-89` fix-ups, `90-99` gates and
cleanup. The order is the file name; nothing else states it.

## system_files/

One tree, copied over `/` by `01-system-files.sh`. What lives where:

| Path | Content |
|---|---|
| `etc/yum.repos.d/*.repo` | every third-party repository, all sections `enabled=0`, `gpgkey=file://` on a key below |
| `etc/pki/rpm-gpg/RPM-GPG-KEY-*` | vendor signing keys, fingerprint pinned in `lib/gpg.sh` |
| `etc/pki/containers/`, `etc/containers/registries.d/` | signing trust for our own images (`11-image-signing.sh`) |
| `usr/lib/modules-load.d/*.conf` | modules loaded at boot (`ip_tables.conf`: `iptable_nat` for docker-in-docker) |
| `usr/share/ublue-os/system-setup.hooks.d/*.sh` | root hooks run by `ublue-system-setup.service` at every boot; each converges on its own (no version stamp) and prints an `ERROR:` line and exits 1 when it cannot |

## State of a build

| Where | Lifetime | Content |
|---|---|---|
| `/tmp/bazzite-mx-build/` (`BUILD_TMP`) | the build `RUN` (tmpfs) | backups a later script restores (`dnf.conf.base`) |
| `/usr/lib/bazzite-mx/build-state/` (`BUILD_STATE`) | shipped in the image | small text records the test `RUN` and a host can read back: `repos.base.sha256` |
| `/var/cache`, `/var/log` | cache mounts, not in the image | dnf cache (fast rebuilds), dnf logs |

## Gates, in order

1. `90-validate-repos.sh` after the last install — the image ships no enabled third-party
   repository and no modified base repository.
2. `tests/run.sh` — every feature's smoke test on the cleaned tree, offline.
3. `bootc container lint --fatal-warnings` — the last word, offline.

Every gate is proven on a known-bad input before it counts (`--self-test` on the scripts,
`docs/conventions.md` § Positive control).
