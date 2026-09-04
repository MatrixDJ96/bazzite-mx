# Gotchas

Facts measured on this project that a reader would otherwise rediscover the hard way. Only
facts still true, each with how and when it was measured; the rules that follow from them live
in [`conventions.md`](conventions.md).

## Torn writeback on the 6.17-azure runner kernel (`ubuntu-24.04`)

On the `ubuntu-24.04` runner image 20260823.283.1 (kernel 6.17.0-1022-azure) a build that
modifies a base-image file in place (`>>`, `cat tmp > file`, an sqlite write: files copied up
into the overlay's upper layer) ships that file with a NUL tail, while every read made during
the build, served from the page cache, sees the right bytes. Measured 2026-09-02 on runs
33623519707, 33627150344 and 33627152814 with probe images (a justfile appended to, an
os-release rewritten, an RPM installed) read cold after `drop_caches` and from the chunked
artefact: the in-place copies were torn, the temp-and-rename copies of the same files intact.
On the `ubuntu-26.04` image 20260824.116.1 (kernel 7.0.0-1012-azure) the same probes were clean
in 4 of 4 arms, chunked artefact included. v1 shipped three corrupted releases this way (its
gotcha #34: rpmdb, master justfile, Flatpak blocklist).

Consequence: CI builds only on `ubuntu-26.04`, and v2 carries neither a cold NUL sweep nor a
fresh-inode helper. A return to `ubuntu-24.04`, or any runner whose kernel is a 6.17-azure,
brings the defect back and reopens both.

## `just`: the earlier import wins on a duplicate recipe name

With `set allow-duplicate-recipes` and the same recipe name in two imported files, just 1.57.0
keeps the recipe of the file imported first (just manual, "Imports"; measured 2026-09-02 with
two files). An import appended after the base's files can never override a base recipe:
`70-justfile.sh` replaces the base file or cuts the recipe out of it instead.

## `grep -v` on an empty set kills a `pipefail` script silently

`... | grep -v '^$' | ...` exits 1 when no line survives the filter, and under
`set -euo pipefail` the script dies without a message (first pre-flight of the justfile commit,
2026-09-02, in `00-prep.sh`). `sed '/^$/d'` exits 0 on an empty set. A dry run in a container
without `set -e` had not caught it: dry runs carry `set -euo pipefail` too.

## `command | grep -q` under `pipefail` fails on a match

`grep -q` exits at the first match and closes the pipe; a writer still producing output dies of
SIGPIPE, the pipeline's status is 141 and `pipefail` reports a failure (third pre-flight of the
kernel-modules commit, 2026-09-02: a helper's `status | grep -q` turned a passing check red).
Capture the output in a variable, then grep the variable.

## `modinfo -F filename` and `modprobe --show-depends` print `/lib/modules/...`

The module tools print the legacy path even when the file lives under `/usr/lib/modules`
(`/lib` is a symlink to `usr/lib`): compare on `realpath` (second pre-flight of the
kernel-modules commit, 2026-09-02).

## `podman build` keeps the base's labels

Without `--label`, the new image carries every label of its `FROM`: a pre-flight image called
itself `Bazzite`, version `44.20260902`, vendor `Universal Blue`, revision the base's commit
(measured 2026-09-02). `image-labels.sh` restates every label on every build.

## A networked RUN leaves `/run/systemd/resolve/stub-resolv.conf` in the image

buildah gives a RUN the host's resolver by binding a file at
`/run/systemd/resolve/stub-resolv.conf` (the target of the base's `/etc/resolv.conf` symlink),
and the directories and the placeholder file stay in the layer: 3 entries under `/run` after
one networked RUN on the base, none when the RUN mounts a tmpfs on `/run` (measured
2026-09-02). `bootc container lint` cannot see them from inside a container, where podman fills
`/run` itself; `check-image.sh` reads `/run` and `/tmp` on the mounted image.

## `ublue-os/remove-unwanted-software` v9 fails on `ubuntu-26.04`

Its apt step runs `apt-get remove -y powershell --fix-missing` and the 26.04 runner image has
no such package: `E: Unable to locate package powershell`, exit 100, the job dead before the
build (run 33644315576, 2026-09-02). The `df` the action prints first showed 92 GB free of
145 GB on that runner, so the image build, the compose archive and the chunked pull (17, 6.6
and 17 GB) fit without freeing anything; the action is not used. aurora and image-template
pin commit `695eb75b` of the action (the `v10` merge, 2025-10-10, without the apt step), which
has no release tag.

## `skopeo` cannot read `containers-storage:` in a runner job

`skopeo inspect containers-storage:<image>` in a rootless job on `ubuntu-26.04` dies with
`Error during unshare(...): Operation not permitted` (run 33645065090, both flavours,
2026-09-02): skopeo needs a user namespace of its own to open podman's rootless storage and
the runner denies it to that binary, while podman itself works. What a step needs from a
local image is read with `podman image inspect` (digest, id, labels); skopeo is used on
`docker://` references only.

## A workflow that is not on the default branch has no runs endpoint

`gh run list --workflow release.yml` and `GET /repos/{owner}/{repo}/actions/workflows/release.yml/runs`
answer `HTTP 404: workflow release.yml not found on the default branch` while the file exists
only on a branch (measured 2026-09-02 15:27Z with `release.yml` on `v2`), and `gh workflow run
release.yml --ref v2` resolves the file the same way. Runs of such a workflow are read from the
repository-wide endpoint `GET /repos/{owner}/{repo}/actions/runs` filtered on `.path`
(`watch-upstream.sh`), and a workflow is dispatched on a branch only once its file is on the
default branch too (`build.yml` is, which is why `--ref v2` works for it).

## A force-push of an unrelated history creates no `push` run

Replacing `develop` (v1, 9d6c054) with the orphan branch `v2` (f248d4b) by force-push created
no run of `build.yml` (measured 2026-09-02 17:44Z, none listed six minutes later; the same
workflow file dispatches fine on that ref). The path filter is a two-dot diff of the pushed
head against the previous head (GitHub docs "Workflow syntax", `on.push.paths`: "If there
are no files changed, the workflow will not run"), and the two heads share no ancestor.
After such a push the profile is dispatched by hand: `gh workflow run build.yml --ref
<branch>` (`-f rechunk=true` for the main profile), and `deploy-pages.yml` likewise.

## `setup-oras` installs only the ORAS versions embedded in its own release

`oras-project/setup-oras` v2.0.1 (2026-07-11) resolves `version` against a list shipped in
the action (`src/lib/data/releases.json`: 1.0.0 … 1.3.0) and fails on any other with
"official ORAS CLI releases does not contain version 1.3.4" (release run 33697633900,
2026-09-03 00:41Z, both flavours, after the push and the signature of `:staging`). The list on
the action's `main` reaches 1.3.4 without a release. `install-oras.sh` installs from the ORAS
release directly, checksum verified.

## `cosign verify --key` reads a certificate-signed referrer before the `.sig`

`ghcr.io/ublue-os/bazzite:stable` (digest `9556db65…`, 2026-09-03) carries its legacy `.sig`
tag, an SPDX SBOM and a SLSA provenance bundle, the last two attached as OCI referrers. cosign
v3.1.3 `verify --key cosign.pub` on it fails with "no matching attestations: expected key
signature, not certificate" and never reaches the `.sig`: the provenance bundle is signed with
a certificate and a key was requested. Our own `:staging` image (legacy `.sig` plus the SBOM
referrer, provenance in the GitHub store only) checked with a throwaway key fails with "no
matching signatures: error verifying bundle: comparing public key PEMs". Measured 2026-09-03
01:30Z locally with the same cosign as the gate; the negative control of `gate-release.sh`
accepted only the second shape and stopped release run 33701006014 as inconclusive.
`cosign_rejected` now classifies both shapes as rejections of the signing material, the
transport errors as inconclusive.

## An inactive package request stays in the origin and keeps bootc incompatible

A layered package the new image already ships is reported by the rebase as an inactive
request ("1password (already provided by 1password-8.12.34-1.x86_64)"): `rpm-ostree status`
lists it under neither `LayeredPackages` nor `packages`, and only `requested-packages` in the
JSON and the origin's `[packages] requested=` still carry it. bootc reads the origin group and
keeps `incompatible: true`. Measured on the hub after the first v2 boot (2026-09-03 06:09Z,
status JSON saved under `/var/tmp/bazzite-mx-migrate/20260903T060914Z/`): `verify-host` and
`migrate plan` read `packages` only and reported nothing to remove. Both read every
`requested-*` list now, and their known-bad fixtures carry the inactive request.

## The 1Password app rejects a BrowserSupport whose group id is below 1000

With `onepassword` created as a system group (gid 951) the Firefox extension never
connects: `1Password-BrowserSupport` verifies the browser, connects to the app and gets
`ConnectionReset`; the app's journal says
`[1P:foundation/op-sys-info/src/process_information/linux.rs:409] invalid group attempted to
connect, rejecting remote` then `Failed to accept new connection.: PipeAuth`. The setgid bit
was in force (the peer's `Gid` line read `1000 951 951 951`), the binary was `root:onepassword`
and `/usr/lib/group` (altfiles) resolved the name. Measured 2026-09-03 07:58-08:01Z on the hub
after the first v2 boot, 1Password 8.12.34, Firefox 154 from Fedora. The rule is documented
by NixOS (`nixos/modules/misc/ids.nix:734`, "1Password requires that its GID be larger than
1000", 31001/31002) and by the Gentoo overlay (`acct-group/onepassword-0.ebuild`, 1010); the
layered v1 host had gid 1001 from the `%post`. `40-desktop-apps.sh` now creates the groups
with the fixed gids 31001 and 31002.

## A local RPM the new image ships blocks the rebase; a layered one does not

Both NVIDIA hosts carried 1Password 8.12.28 as a local package (`rpm-ostree install
./1password.rpm`). The upgrade onto the v2 image, which ships 8.12.34, failed to depsolve:
"cannot install both 1password-8.12.28-1.x86_64 from @commandline and 1password-8.12.34-1.x86_64
from @System — conflicting requests" (measured 2026-09-04 00:30Z on ldesktop-matrix and
llaptop-matrix, log under `/var/tmp/bazzite-mx-upgrade.log`). The hub had layered the same
package from the vendor repository and its rebase went through with an inactive request
([above](#an-inactive-package-request-stays-in-the-origin-and-keeps-bootc-incompatible)): a
repository request is re-resolved against the new base, a local one is the file itself.
`rpm-ostree upgrade --uninstall=<nevra>` drops the request in the same transaction
([`migration.md`](migration.md)).

## An EXIT trap cannot read a `local` of the function that armed it

`bazzite-mx-migrate apply` kept `timer_was_active` as a `local` of `cmd_apply` and armed
`trap restore_timer EXIT` from there: the trap runs after the function has returned, the local
is gone, and under `set -u` bash dies with "timer_was_active: unbound variable" — after every
step had run. Measured on the hub (2026-09-03 23:40Z, image `44.20260903.2`): `apply` on the
already migrated host printed step 7 and `rpm-ostree status`, then exited 1 and left
`uupd.timer` stopped (restored by hand). The pilot never saw it because its steps ran by hand.
State a trap reads lives at script level (`TIMER_WAS_ACTIVE`), and the self-test arms the trap
in a child shell and requires the restart line.

## A `blob/main` link is dead until the file is on `main`

`https://github.com/<owner>/<repo>/blob/main/<path>` and the raw form answer 404 while
`<path>` exists only on a branch (measured 2026-09-02 17:15Z: the landing page's link to
`docs/migration.md`, a v2 file, on a `main` still at v1). `check-site.sh` resolves such links
on the checkout instead of fetching them: the page and the file it points at ship in the same
push.

## `ghcr-cleanup-action` matches `packages` by pattern only with `expand-packages`

`use-regex: true` reaches `delete-tags` and `exclude-tags`; `packages` stays a comma-separated
list of literal names unless `expand-packages: true`, which lists the owner's packages through
the Packages API and requires a classic PAT (`src/main.ts:50-90` and `src/config.ts:92-100` at
v1.2.2, read 2026-09-02; `GITHUB_TOKEN` is refused there). With `expand-packages` and
`use-regex`, the whole `packages` string is ONE regular expression, not a list of them.

## A kbuild fragment gated on a kernel config symbol compiles nothing and exits 0

`make -C /usr/src/kernels/<kver> M=<clone> modules` on `namjaejeon/linux-ntfs` prints
`MODPOST Module.symvers`, exits 0 and produces no `.ko`: its fragment is
`obj-$(CONFIG_NTFS_FS) += ntfs.o`, which expands to `obj- += ntfs.o` against a kernel that
leaves the symbol unset, a variable kbuild never reads. The module's own top-level `Makefile`
hides this with `export CONFIG_NTFS_FS := m`, in the branch a direct `-C <kernel> M=` call
bypasses. Measured 2026-09-04 on 7.2.1-ogc4.1 and 6.18.48-ogc1.1: nothing without the symbol,
`ntfs.ko` with `CONFIG_NTFS_FS=m` on the make line. `source.env` carries the symbol as
`KO_BUILD_ARGS`, `build-kmods.sh` refuses a build that produced no file, and `55-ntfsplus.sh`
asserts the `fs-ntfs` alias. `msi-ec` and `acpi_ec` are immune: unconditional `obj-m +=`.

## `mount -t ntfs` reaches the kernel driver only when no `mount.ntfs` helper exists

With the NTFSPLUS module loaded and `ntfs` in `/proc/filesystems`, `mount -t ntfs` still
lands on ntfs-3g (`findmnt` reports `fuseblk`): `mount(8)` hands any type with a
`/sbin/mount.<type>` helper to that helper before the kernel sees the type, and the ntfs-3g
package links `mount.ntfs` and `mount.ntfs-fuse` to `mount.ntfs-3g` in both `/usr/bin` and
`/usr/sbin` (six links on the base, measured 2026-09-04). fstab rows, `.mount` units and
`mount -t auto` go the same way, since libblkid reports the type as `ntfs`. `mount -i` skips
the helper and has no fstab equivalent, which is why the removal happens in the image
(`55-ntfsplus.sh`); `mount.ntfs-3g` stays as the explicit FUSE route.

## A kernel module can pass vermagic and modinfo and panic at its first use

v1's first build on a new kernel series shipped an NTFSPLUS pin that predated an iomap fix
the module needed under that series: the build and its vermagic guard were green, and every
host with an NTFS row in fstab kernel-panicked seconds after `Switching root` — before
`systemd-journal-flush`, so the journal held nothing and pstore was empty; the evidence lived
on the console alone (two hosts, three panics, 2026-08-28). A build-time guard cannot catch
this class: the breakage is a runtime API mismatch, and a real mount needs a booted target
kernel. Every pin bump therefore takes the runtime proof on a booted host, and
`bazzite-mx-ntfsplus-setup enable` runs that proof (format, mount as `ntfs`, write, remount,
checksum on a loop image) before it rewrites a single fstab row.

## The two NTFS kernel drivers agree on modes and case, with two permissive exceptions

On a volume mounted `umask=000` the mode bits come from the WSL metadata EAs `$LXMOD`,
`$LXUID`, `$LXGID` (written by WSL and by both drivers), not from the mask: an object carrying
`$LXMOD` reports exactly that mode. `ntfs3` lets `$LXUID`/`$LXGID` override the mount's
`uid=`/`gid=`, NTFSPLUS lets the mount option win; `ntfs3` subtracts the write bits for the
DOS read-only attribute, NTFSPLUS reads none at inode load. Both differences are
permissive-only (no object loses a bit) and the round trip is lossless. Both drivers mount
case-sensitive by default and accept `nocase`. Measured 2026-07-30 on the fleet's desktop,
fresh mounts on both sides (a mount already up serves `$LXMOD` from the cached inode).

