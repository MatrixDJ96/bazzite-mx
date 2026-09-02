# Architecture

How an image is built, what each stage may touch, and where the state of a build lives.

## Build flow

```
Containerfile
  ctx           FROM scratch, COPY build_files, system_files, cosign.pub   never part of the image, bound at /ctx
  kmod-builder  FROM ${BASE_IMAGE}: build_files/kmods/build-kmods.sh --self-test, then the build → /out/<kver>/updates/*.ko
  image         FROM ${BASE_IMAGE}
    RUN /ctx/build_files/build.sh                    mounts: /kmods (from kmod-builder), /var/cache, /var/log (cache), /tmp (tmpfs)
    RUN /ctx/build_files/tests/run.sh                offline; tmpfs on /run and /tmp
    RUN bootc container lint --fatal-warnings        offline; tmpfs on /run
```

The kernel modules are built by the base image itself (it ships `kernel-devel` for its own
kernel, versionlocked, plus gcc, make, binutils and git-core; measured 2026-09-02), so no
akmods carrier stage exists. The staged modules are bound at `/kmods`, a root-level mount point
buildah removes after the RUN: a stage mount under `/tmp`, `/var` or `/run` makes clean-stage's
`find -delete` fail on the read-only bind (measured 2026-09-02).

`BASE_IMAGE` is the only variable between the two flavours; `IMAGE_NAME` follows it
(`resolve-base.sh` prints both) and `VERSION` is the version the image calls itself: the
release tag, or `<base version>.dev` for a sandbox or pre-flight build. CI and `/preflight`
resolve the base to a digest with `.github/scripts/resolve-base.sh`, which also reads the
base's kernel from its `ostree.linux` label, and take `VERSION` and every `--label` from
`.github/scripts/image-labels.sh` (the `.dev` rule is stated there; `10-image-info.sh` repeats
it for a `podman build` by hand with no `VERSION`).

## CI

```
build.yml            push to main or develop, pull request, dispatch (input rechunk)
  lint               ubuntu-26.04: shellcheck; shfmt and yamllint from Fedora 44; node --check on the
                     Plasma update scripts; just --unstable --fmt --check on the .just files (just from
                     Linuxbrew); --self-test of every script under .github/scripts/
  build              reusable-build.yml with rechunk = (ref == main) or the dispatch input
release.yml          workflow_dispatch only (reason, promote_stable): version → build → gate → release,
                     step by step in docs/workflow.md § The release run
promote.yml          workflow_dispatch (release_tag): gate-release.sh promote → :stable
sign-image.yml       workflow_dispatch (image): sign one of our images by digest, verify
reusable-build.yml   workflow_call: release_tag ("" in the sandbox), rechunk, publish; secret SIGNING_SECRET
  matrix             bazzite, bazzite-nvidia-open on ubuntu-26.04, fail-fast off
  resolve-base.sh    → base.env: base digest, base version, kernel, image name
  image-labels.sh    → labels.txt: every label of the image (version = release_tag or <base>.dev)
  podman build       --build-arg BASE_IMAGE, IMAGE_NAME, VERSION; --label per line of labels.txt
  sandbox profile    check-image.sh on the built image
  main profile       the chunked image (build-chunked-oci), its probe, a test signature with SIGNING_SECRET
  release profile    (publish) SBOM, push :staging by digest, signature, attestation, release-<flavour>.env;
                     the three profiles in docs/workflow.md § Branches and profiles and § The release run
```

Nothing in `build.yml` pushes to GHCR or creates a release (decision 1.5d): the main profile
proves, on every push to `main`, the artefact a release run would publish and the key it would
sign with. The main profile runs on any ref with
`gh workflow run build.yml --ref <branch> -f rechunk=true`, which is how a change to it is
proven before it reaches `main`. The release run, the promotions and the recovery signer are
described in [`workflow.md`](workflow.md).

| Script | Role |
|---|---|
| `lib.sh` | sourced by every script: `REPO`, `REGISTRY`, `BASE_REGISTRY`, `PACKAGES`, `TAG_SHAPE`, `fail`/`err` with the script's name, `emit` (stdout and `GITHUB_OUTPUT`), `read_env` (the build's env file, every value in shape); run directly, `--self-test` |
| `resolve-base.sh <flavour>` | the base's digest, version and kernel and the flavour's image name, from `skopeo inspect` of `ghcr.io/ublue-os/<flavour>:stable`; `--from-json` for a saved inspect; `--self-test` |
| `image-labels.sh <coords> <release-tag> <revision>` | the labels file: OCI title, description, source, url, vendor, licenses, version, revision, created, `base.name`, `base.digest`; `ostree.bootable`, `ostree.linux`, `containers.bootc`; every value required; `--self-test` |
| `check-image.sh <image> <labels-file>` | the probe of the artefact: every label present with its value; `/run` and `/tmp` empty on the mounted image; inside the image `bootc container lint --fatal-warnings`, `rpm -q` of docker-ce, code and 1password, the two MSI modules under `updates/` for the labelled kernel and resolved by modprobe, `image-info.json` at the labelled version; `--self-test` on the label gate |
| `release-tag.sh <coords>` | the release tag `<fedora>.<yyyymmdd>`, `.N` only when taken on either GHCR package or on a GitHub Release; a probe returning nothing aborts; `--from-lists` for saved lists; `--self-test` |
| `gate-release.sh release\|promote` | the gate: reads the build's env files, checks the manifest's labels by digest, shows both verifiers failing on the base image, `cosign verify` and `gh attestation verify --repo`, copies the digest onto `:<tag>` (never over another digest) and, on promotion, `:stable`; `--self-test` on the label, env and tag-state checks |
| `changelog.sh release` | the release notes: base version and kernel from the base's labels, the previous release from `gh release list`, package diff of the two SBOM referrers (stated when the previous release carries none), commits since the previous revision, switch commands; prints the title; `--self-test` |
| `refresh-pins.sh` | the pin refresh: actions, binaries, runner labels, workflow states, cited issues (`--check`), `--apply` for the first two classes; offline `--self-test` on fixtures ([`workflow.md`](workflow.md) § Keeping the pins fresh) |

## build_files/

| Path | Role |
|---|---|
| `build.sh` | orchestrator: runs `NN-<feature>.sh` in version order, one `::group::` each, stops at the first failure (bazzite-dx `build_files/build.sh:13-27`) |
| `lib/env.sh` | sourced first by every script: `CTX`, `BUILD_FILES`, `BUILD_TMP`, `BUILD_STATE`, then `log.sh`, `repos.sh`, `gpg.sh` and `just.sh` |
| `lib/log.sh` | `group`, `endgroup`, `log`, `die` |
| `lib/repos.sh` | `install_from_repo <id> <pkg>..` (vendored `.repo`, enabled for one transaction), `copr_install_isolated <owner/project> <pkg>..` (aurora `copr-helpers.sh:4-23`) |
| `lib/just.sh` | `recipe_set <justfile>` (the recipe names, sorted), `has_recipe <justfile> <name>`: output captured before any grep (`just … \| grep -q` dies of SIGPIPE under pipefail) |
| `lib/kmod.sh` | `kernel_version` (the image's one kernel), `assert_module <ko> <kver> [<version>]` (readable, vermagic names the kernel, MODULE_VERSION): sourced by the kmod-builder stage and by `50-kmods.sh` |
| `lib/gpg.sh` | `KEY_FPR` (the pinned fingerprint of every vendored key, with its source), `key_fingerprint <file>`, `assert_key_fingerprint <file> [<fpr>]`: the vendored key's fingerprint against the table, before the install that trusts it |
| `00-prep.sh` | dnf keeps its cache during the build (aurora `build-prep.sh:8-9`); records the base's `.repo` files by checksum and its `ujust` recipe files by recipe set |
| `01-system-files.sh` | `rsync -rlpvK` of `system_files/` over the tree: every file lands on a fresh inode with the mode git stores |
| `10-image-info.sh` | identity: `image-info.json` (name, vendor, signed `image-ref`, `version`, `base-version`), os-release `VARIANT_ID`/`IMAGE_ID`, KDE About page (bazzite-dx `00-image-info.sh` form) |
| `11-image-signing.sh` | `cosign.pub` → `/etc/pki/containers/matrixdj96.pub`; `policy.json` scope `ghcr.io/matrixdj96` = `sigstoreSigned` + `matchRepository` (written with jq to a new file, then renamed) |
| `20-setup-services.sh` | hook framework `ublue-setup-services` (COPR `ublue-os/packages`): `ublue-system-setup.service` runs `system_files/usr/share/ublue-os/system-setup.hooks.d/*` as root at boot, before user sessions; the user unit is enabled by its first consumer |
| `21-container-runtime.sh` | Docker CE (five packages, vendored stable repo, key asserted), podman-compose/machine/tui and bcvk from Fedora, `docker.socket` + `podman.socket` enabled; the `docker` group the %post creates is relocated by clean-stage and granted to wheel users at boot by the hook `10-bazzite-mx-groups.sh` |
| `22-virtualization.sh` | libvirt (modular daemons from the Fedora preset, `libvirtd.service` never enabled), QEMU/KVM, virt-manager, swtpm, guestfs-tools, waypipe, quickemu; `ublue-os-libvirt-workarounds` (COPR); asserts binfmt stays out and that the recipe file parses |
| `30-ide.sh` | VS Code from the vendored Microsoft repo (key asserted); enables `ublue-user-setup.service` for every user, the first user hook being the extensions one |
| `31-git-tools.sh` | GitKraken from the vendor's fixed URL (latest release, unsigned RPM: TLS + payload digests, `--no-gpgchecks` for that file only), git-credential-libsecret |
| `32-cli-rpms.sh` | gh, glab, ShellCheck, shfmt and the system-administration list, all Fedora |
| `33-mise.sh` | mise from the vendored `jdxcode/mise` COPR (key asserted); activation and default runtimes come from system_files |
| `40-desktop-apps.sh` | Firefox and gparted from Fedora, `deny org.mozilla.firefox/*` appended to the base's Flatpak filter, 1Password from the vendored repo (key asserted, `/var/opt` created first, the `.repo` its %post rewrites put back, polkit actions and groups checked) |
| `41-sunshine.sh` | Sunshine from the vendored COPR `lizardbyte/stable` (key asserted): KMS capabilities, udev and modules-load files checked, user unit disabled for everyone, Bazzite's Portal announcement removed, recipe `82-bazzite-sunshine.just` (replacing the base's) checked |
| `kmods/build-kmods.sh` | kmod-builder stage: for every `kmods/<name>/source.env` (URL, pinned COMMIT, KO_NAME, KO_BUILD_PATH, KO_VERSION) fetch the commit, prove the checkout is that commit, `make -C /usr/src/kernels/<kver> M=<clone> modules`, `strip --strip-debug`, stage under `/out/<kver>/updates/`, assert readable, vermagic for `<kver>`, MODULE_VERSION; `--self-test` |
| `45-kde-defaults.sh` | KDE defaults from system_files: two Plasma update scripts (clock seconds, a panel per screen), skel Konsole shortcut file and PowerShell profile, the `setup-panels` recipe; the script proves the files landed where their consumers read them and are well formed |
| `50-kmods.sh` | installs the staged `msi-ec.ko` and `acpi_ec.ko` into `/usr/lib/modules/<kver>/updates/` (depmod searches `updates` first: kmod `tools/depmod.c:913-917`), runs `depmod`, asserts vermagic, version and that `modprobe` resolves each name to the new copy; nothing loads them at boot |
| `70-justfile.sh` | `ujust`: drift guard on the base files we replace (recipe set equal to the snapshot), the base's `install-jetbrains-toolbox` cut out of `82-bazzite-apps.just` (the earlier import wins on duplicates), `95-bazzite-mx.just` imported into the master justfile on a fresh inode, no name defined twice, `just --list` runs, our files `--fmt` clean; `--self-test` |
| `80-fix-opt.sh` | every `/var/opt/<name>` an RPM unpacked moves to `/usr/lib/opt/<name>`, with a generated `usr/lib/tmpfiles.d/bazzite-mx-opt.conf` (`L+` per name) that recreates the `/var/opt` link at boot; checks before the first move, `--self-test` |
| `90-validate-repos.sh` | repository gate: vendored files present, identical and disabled; base files untouched; additions disabled; `--self-test` |
| `95-clean-stage.sh` | dnf.conf restored, dnf history removed, accounts relocated to `/usr/lib`, rpmdb hardlinked, `/var` `/run` `/tmp` `/boot` swept (aurora `clean-stage.sh`, bazzite `finalize`, `cleanup`) |
| `tests/run.sh` | test runner: pairing guard (every `NN-x.sh` has `tests/NN-x.sh` and vice versa), `OK:`/`FAIL:` protocol, `--self-test` |
| `tests/lib.sh` | the checks the tests share, one `OK:`/`FAIL:` line each: `check_pkg`, `check_unit_state [--global]`, `check_desktop_file`, `check_just_fmt`, `check_recipe_help`; brings `lib/just.sh` |
| `tests/NN-x.sh` | one smoke test per build script, same stem |

Numbering: `00-09` preparation, `10-19` identity and trust, `20-49` package installation and
desktop defaults, `50-59` kernel modules, `60-69` services, `70-79` justfile, `80-89` fix-ups
(`/opt` relocation), `90-99` gates and cleanup. The order is the file name; nothing else states
it.

## system_files/

One tree, copied over `/` by `01-system-files.sh`. What lives where:

| Path | Content |
|---|---|
| `etc/yum.repos.d/*.repo` | every third-party repository, all sections `enabled=0`, `gpgkey=file://` on a key below |
| `etc/pki/rpm-gpg/RPM-GPG-KEY-*` | vendor signing keys, fingerprint pinned in `lib/gpg.sh` |
| `etc/pki/containers/`, `etc/containers/registries.d/` | signing trust for our own images (`11-image-signing.sh`) |
| `usr/lib/modules-load.d/*.conf` | modules loaded at boot (`ip_tables.conf`: `iptable_nat` for docker-in-docker) |
| `usr/lib/modprobe.d/bazzite-mx-*.conf` | module options (`kvm ignore_msrs`) |
| `usr/lib/tmpfiles.d/bazzite-mx-*.conf` | `/var` directories packages ship and clean-stage removes; a host recreates them at boot (`bazzite-mx-opt.conf` is not in system_files: `80-fix-opt.sh` generates it from what sits under `/var/opt`) |
| `usr/lib/bazzite-mx/host.sh` | what `verify-host` and `migrate` both read about the host (booted deployment, request lists, policy scope, fstab rows, ntfsplus residue) and their one fixture routing (`FIXTURE=`); sourced, never run |
| `usr/libexec/` | helpers recipes call, each with a fixture knob for its smoke test: `bazzite-dx-kvmfr-setup` (bazzite-dx's file plus its two bold codes), `bazzite-mx-msi-setup` (the root half of `setup-msi`; `ROOT=`, `DMI_VENDOR_FILE=`), `bazzite-mx-verify-host` (the checks of `verify-host`; `FIXTURE=`), `bazzite-mx-migrate` (`plan`/`apply` of `migrate`; `FIXTURE=` for plan, `--self-test`), `bazzite-mx-jetbrains-toolbox` (the user half of `install-jetbrains-toolbox`; `FEED_URL=`, `CURL_PROTO=`, `NO_LAUNCH=`) |
| `usr/share/ublue-os/just/*.just` | `ujust` recipes; a file with a base file's name replaces that file (the base justfile already imports it, and `70-justfile.sh` proves it held only the recipes we ship), `95-bazzite-mx.just` is imported by `70-justfile.sh` |
| `usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/bazzite-mx-*.js` | Plasma update scripts: plasmashell runs each once per user at start, in file-name order, and records it in `~/.config/plasmashellrc` (`[Updates] performed`); the way Plasma and Bazzite (`bazzite-pins.js`) ship one-shot per-user defaults |
| `etc/skel/.config/`, `etc/skel/.local/share/` | per-user defaults a new account starts from (VS Code `update.mode`, mise runtimes, PowerShell profile, Konsole `kxmlgui5/konsole/sessionui.rc`); hooks seed them for existing accounts where it matters |
| `etc/profile.d/*.sh` | shell activation (`mise.sh`, interactive bash) |
| `usr/share/ublue-os/user-setup.hooks.d/*.sh` | per-user hooks run by `ublue-user-setup.service` in every graphical session; same rules as the system hooks below |
| `usr/share/ublue-os/system-setup.hooks.d/*.sh` | root hooks run by `ublue-system-setup.service` at every boot; each converges on its own (no version stamp) and prints an `ERROR:` line and exits 1 when it cannot |

## State of a build

| Where | Lifetime | Content |
|---|---|---|
| `/tmp/bazzite-mx-build/` (`BUILD_TMP`) | the build `RUN` (tmpfs) | backups a later script restores (`dnf.conf.base`) |
| `/usr/lib/bazzite-mx/build-state/` (`BUILD_STATE`) | shipped in the image | small text records the test `RUN` and a host can read back: `repos.base.sha256`, `just.base.summary` (the base's recipe files by recipe set) |
| `/var/cache`, `/var/log` | cache mounts, not in the image | dnf cache (fast rebuilds), dnf logs |

## Gates, in order

1. `90-validate-repos.sh` after the last install — the image ships no enabled third-party
   repository and no modified base repository.
2. `tests/run.sh` — every feature's smoke test on the cleaned tree, offline.
3. `bootc container lint --fatal-warnings` — the last word, offline.

Every gate is proven on a known-bad input before it counts (`--self-test` on the scripts,
`docs/conventions.md` § Positive control).
