# Gotchas

Surprises found on this project that a reader would otherwise rediscover the hard way. Each one
says what happens, how and when it was measured, and what the repository does about it. The
rules themselves live in [`conventions.md`](conventions.md).

## Torn writeback on a 6.17-azure runner kernel

A build that modifies a base-image file in place ships that file with a NUL tail. The cases are
`>>`, `cat tmp > file` and an sqlite write, all of which copy the file up into the overlay's
upper layer. Every read made during the build, served from the page cache, sees the right
bytes.

Measured 2026-09-02 on the `ubuntu-24.04` runner image 20260823.283.1 (kernel
6.17.0-1022-azure) with probe images read cold after `drop_caches` and from the chunked
artefact: the in-place copies were torn, the temp-and-rename copies of the same files intact.
On the `ubuntu-26.04` image 20260824.116.1 (kernel 7.0.0-1012-azure) the same probes were clean
in 4 of 4 arms.

CI builds only on `ubuntu-26.04` for this reason, and the image carries neither a cold NUL
sweep nor a fresh-inode helper. A runner whose kernel is a 6.17-azure brings the defect back.

## `just`: the earlier import wins on a duplicate recipe name

With `set allow-duplicate-recipes` and the same recipe name in two imported files, just keeps
the recipe of the file imported first (just manual, "Imports"; measured 2026-09-02 with two
files on just 1.57.0). An import appended after the base's files can never override a base
recipe, so `70-justfile.sh` replaces the base file or cuts the recipe out of it, and fails the
build on any name defined twice.

## `grep -v` on an empty set kills a `pipefail` script silently

`... | grep -v '^$' | ...` exits 1 when no line survives the filter, and under `set -euo
pipefail` the script dies without a message (measured 2026-09-02 in `00-prep.sh`, first
pre-flight of the justfile feature). `sed '/^$/d'` exits 0 on an empty set and is what
`recipe_set` uses in `lib/just.sh`. A dry run in a container without `set -e` had not caught
it, dry runs carrying `set -euo pipefail` too.

## `command | grep -q` under `pipefail` fails on a match

`grep -q` exits at the first match and closes the pipe; a writer still producing output dies of
SIGPIPE, the pipeline's status is 141 and `pipefail` reports a failure. Measured 2026-09-02: a
helper's `status | grep -q` turned a passing check red during the pre-flight of the
kernel-modules feature. Capture the output in a variable, then grep the variable.

## `modinfo -F filename` and `modprobe --show-depends` print `/lib/modules/...`

The module tools print the legacy path even when the file lives under `/usr/lib/modules`
(`/lib` being a symlink to `usr/lib`), so a literal string comparison against the staged path
fails (measured 2026-09-02). `50-kmods.sh` and `55-ntfsplus.sh` compare `realpath` of the
resolved module against `realpath` of the file they installed.

## `modprobe -n --show-depends` resolves an alias through its blacklist

With `blacklist ntfs` in force, `modprobe -n -v fs-ntfs` prints nothing, which is what the
kernel's `request_module("fs-ntfs")` gets, while `modprobe -n --show-depends fs-ntfs` prints
`insmod .../updates/ntfs.ko` as if the alias were free (measured 2026-09-05, kmod on
`7.2.1-ogc4.1.fc44`; `-b` makes no difference to either). A probe of "would the kernel load
it by alias" is the `-n -v` form; `--show-depends` answers "where does the module live".
The same probe read the blacklist through `! modprobe -c | grep -q`, the SIGPIPE shape of
§ `command | grep -q` above on a 2 MB config, so its negation was never false: the config is
captured first (`bazzite-mx-ntfsplus-setup`, `alias_resolves`).

## `podman build` keeps the base's labels

Without `--label`, the new image carries every label of its `FROM`: a pre-flight image called
itself `Bazzite`, vendor `Universal Blue`, revision the base's commit (measured 2026-09-02).
`image-labels.sh` restates every label on every build, and the same file is passed again to
`build-chunked-oci`, which inherits no config either.

## A networked RUN leaves `/run/systemd/resolve/stub-resolv.conf` in the image

buildah gives a RUN the host's resolver by binding a file at
`/run/systemd/resolve/stub-resolv.conf`, the target of the base's `/etc/resolv.conf` symlink.
The directories and the placeholder file then stay in the layer: 3 entries under `/run` after
one networked RUN on the base, none when the RUN mounts a tmpfs on `/run` (measured
2026-09-02). Every `RUN` of the `Containerfile` therefore mounts a tmpfs on `/run` and `/tmp`.
`bootc container lint` cannot see them from inside a container, where podman fills `/run`
itself, so `check-image.sh` reads both directories on the mounted image instead.

## `ublue-os/remove-unwanted-software` v9 fails on `ubuntu-26.04`

Its apt step runs `apt-get remove -y powershell --fix-missing` and the 26.04 runner image has
no such package: `E: Unable to locate package powershell`, exit 100, the job dead before the
build (measured 2026-09-02). The `df` the action prints first showed 92 GB free of 145 GB on
that runner, so the image build, the compose archive and the chunked pull fit without freeing
anything. The action is not used. aurora and image-template pin commit `695eb75b` of the
action, the `v10` merge without the apt step, which has no release tag.

## `skopeo` cannot read `containers-storage:` in a runner job

`skopeo inspect containers-storage:<image>` in a rootless job on `ubuntu-26.04` dies with
`Error during unshare(...): Operation not permitted` (measured 2026-09-02 on both flavours):
skopeo needs a user namespace of its own to open podman's rootless storage and the runner
denies it to that binary, while podman itself works. What a step needs from a local image is
read with `podman image inspect`; skopeo is used on `docker://` references only.

## A workflow that is not on the default branch has no runs endpoint

`gh run list --workflow release.yml` and the API path `GET
/repos/{owner}/{repo}/actions/workflows/release.yml/runs` answer `HTTP 404: workflow
release.yml not found on the default branch` while the file exists only on a branch (measured
2026-09-02). `gh workflow run release.yml --ref <branch>` resolves the file the same way. Runs
of such a workflow are read from the repository-wide endpoint filtered on `.path`
(`watch-upstream.sh`), and a workflow is dispatched on a branch only once its file is on the
default branch too.

## A force-push of an unrelated history creates no `push` run

Force-pushing a branch onto a head that shares no ancestor with the previous one created no run
of `build.yml`, while the same workflow file dispatched fine on that ref (measured 2026-09-02:
no run listed six minutes after the push). A path filter is a two-dot diff of the pushed head
against the previous head, and GitHub documents the empty case ("Workflow syntax",
`on.push.paths`: "If there are no files changed, the workflow will not run"). After such a push
the profile is dispatched by hand, `gh workflow run build.yml --ref <branch>`, and
`deploy-pages.yml` likewise.

## `setup-oras` installs only the ORAS versions embedded in its own release

`oras-project/setup-oras` v2.0.1 resolves `version` against a list shipped in the action,
`src/lib/data/releases.json`, which runs from 1.0.0 to 1.3.0. Any other version fails with
"official ORAS CLI releases does not contain version 1.3.4" (measured 2026-09-03 on both
flavours, after the push and the signature of `:staging`). The list on the action's `main`
reaches 1.3.4 without a release. `install-oras.sh` installs from the ORAS release directly, the
tarball refused unless its sha256 matches the release's checksums file.

## `cosign verify --key` reads a certificate-signed referrer before the `.sig`

`ghcr.io/ublue-os/bazzite:stable` carries its legacy `.sig` tag, an SPDX SBOM and a SLSA
provenance bundle, the last two attached as OCI referrers. cosign v3.1.3 `verify --key
cosign.pub` on it fails with "no matching attestations: expected key signature, not
certificate" and never reaches the `.sig`: the provenance bundle is signed with a certificate
and a key was requested. An image of ours, checked with a throwaway key, fails instead with "no
matching signatures: error verifying bundle: comparing public key PEMs". Measured 2026-09-03
locally with the same cosign as the gate, after a negative control that accepted only the
second shape stopped a release run as inconclusive. `cosign_rejected` in `gate-release.sh`
classifies both shapes as rejections of the signing material and leaves the transport errors
inconclusive.

## An inactive package request stays in the origin and keeps bootc incompatible

A layered package the new image already ships is reported by the rebase as an inactive request
("1password (already provided by 1password-8.12.34-1.x86_64)"): `rpm-ostree status` lists it
under neither `LayeredPackages` nor `packages`, and only `requested-packages` in the JSON and
the origin's `[packages] requested=` still carry it. bootc reads the origin group and keeps
`incompatible: true` (measured 2026-09-03 on the first boot after such a rebase, where a reader
that looked at `packages` alone reported nothing to remove). `layered_requests` in `host.sh`
reads every `requested-*` list, `verify-host` and `migrate` both go through it, and their
known-bad fixtures carry the inactive request.

## The 1Password app rejects a BrowserSupport whose group id is below 1000

With `onepassword` created as a system group (gid 951) the Firefox extension never connects:
`1Password-BrowserSupport` verifies the browser, connects to the app and gets
`ConnectionReset`, while the app's journal says

```
[1P:foundation/op-sys-info/src/process_information/linux.rs:409] invalid group attempted to connect, rejecting remote
Failed to accept new connection.: PipeAuth
```

The setgid bit was in force (the peer's `Gid` line read `1000 951 951 951`), the binary was
`root:onepassword` and `/usr/lib/group` resolved the name through altfiles. Measured 2026-09-03
with 1Password 8.12.34 and Firefox 154 from Fedora. The rule is documented by NixOS
(`nixos/modules/misc/ids.nix`, "1Password requires that its GID be larger than 1000",
31001/31002) and by the Gentoo overlay (`acct-group/onepassword`, 1010); `40-desktop-apps.sh`
creates the two groups with the fixed gids 31001 and 31002.

## A local RPM the new image ships blocks the rebase; a repository package does not

A host carrying 1Password 8.12.28 as a local package (`rpm-ostree install ./1password.rpm`)
cannot upgrade onto an image that ships 8.12.34: the depsolve fails with "cannot install both
1password-8.12.28-1.x86_64 from @commandline and 1password-8.12.34-1.x86_64 from @System:
conflicting requests" (measured 2026-09-04 on two hosts). The same package layered from the
vendor repository rebases through and leaves an inactive request. A repository request is
re-resolved against the new base, where a local one is the file itself. `rpm-ostree upgrade
--uninstall=<nevra>` drops the request in the same transaction
([`migration.md`](migration.md)).

## An EXIT trap cannot read a `local` of the function that armed it

`bazzite-mx-migrate apply` kept `timer_was_active` as a `local` of `cmd_apply` and armed `trap
restore_timer EXIT` from there. The trap runs after the function has returned, the local is
gone, and under `set -u` bash dies with "timer_was_active: unbound variable" once every step
has run. Measured 2026-09-03 on an already migrated host: `apply` printed step 7 and
`rpm-ostree status`, then exited 1 and left `uupd.timer` stopped. Running the same steps by
hand never shows it. State a trap reads lives at script level (`TIMER_WAS_ACTIVE`), and the
self-test arms the trap in a child shell and requires the restart line.

## A private marker does not identify an installation the recipe did not make

`bazzite-mx-jetbrains-toolbox` recorded the build it unpacked in its own file,
`.bazzite-mx-build`, and read only that. Measured 2026-09-05 on a laptop whose Toolbox at
`~/.local/share/JetBrains/ToolboxApp` came from an earlier recipe: `status` said "not
installed" while `bin/jetbrains-toolbox` existed and was running, and `install` refused with
"quit it first" before re-downloading the identical build. The tarball carries the build in
`bin/build.txt` (3.7.2.87231, equal to the feed's `build` field), so the helper reads that,
whoever unpacked the tree, and refuses a tarball without it.

## mise installs the dotnet SDK in `~/.dotnet`, not under its own installs directory

`mise install dotnet@10` runs Microsoft's `dotnet-install` script with `~/.dotnet` as the
target and leaves `~/.local/share/mise/installs/dotnet/<version>` as a symlink to it. Measured
2026-09-05 on a host with a hand-installed SDK 10.0.300 in `~/.dotnet`: the run added SDK
10.0.400 and runtime 10.0.11 next to it and rewrote the `dotnet` muxer, with `MISE_DATA_DIR`
pointed elsewhere. `ujust setup-dev help` says so; the other runtimes stay under
`installs/`.

## A deleted immutable release keeps its tag name burnt

With immutable releases on (the repository setting in [`workflow.md`](workflow.md)), a tag name
that ever carried a published release is refused for good: `gh release create` answers `HTTP
422 … tag_name was used by an immutable release`, and so does `POST /git/refs` for a bare tag,
with the setting switched off as well. Measured 2026-09-05 after `gh release delete
44.20260905 --cleanup-tag`: the rebuilt release run promoted its three images to GHCR as
`44.20260905` and died in the release job; the retry with the setting off died the same way.
`release-tag.sh` probes GHCR and the release list, neither of which lists a burnt name, so the
rule is procedural: a release is never deleted to reuse its name; the next release takes the
next free name (`.N`, or the next day). `cleanup.sh` deletes only names that never come back.

## A `blob/main` link is dead until the file is on `main`

`https://github.com/<owner>/<repo>/blob/main/<path>` and the raw form answer 404 while `<path>`
exists only on a branch (measured 2026-09-02 on the home page's link to `docs/migration.md`, a
file not yet on `main`). `check-site.sh` resolves such links on the checkout instead of
fetching them, so the page and the file it points at ship in the same push.

## `ghcr-cleanup-action` matches `packages` by pattern only with `expand-packages`

`use-regex: true` reaches `delete-tags` and `exclude-tags`; `packages` stays a comma-separated
list of literal names unless `expand-packages: true`, which lists the owner's packages through
the Packages API and requires a classic PAT (`src/main.ts` and `src/config.ts` at v1.2.2, read
2026-09-02; `GITHUB_TOKEN` is refused there). With `expand-packages` and `use-regex`, the whole
`packages` string is one regular expression, not a list of them. `clean.yml` names the three
packages one by one.

## A kbuild fragment gated on a kernel config symbol compiles nothing and exits 0

`make -C /usr/src/kernels/<kver> M=<clone> modules` on `namjaejeon/linux-ntfs` prints `MODPOST
Module.symvers`, exits 0 and produces no `.ko`. Its fragment is `obj-$(CONFIG_NTFS_FS) +=
ntfs.o`, which expands to `obj- += ntfs.o` against a kernel that leaves the symbol unset, a
variable kbuild never reads. The module's own top-level `Makefile` hides this with `export
CONFIG_NTFS_FS := m`, which a direct `-C <kernel> M=` call bypasses. Measured 2026-09-04 on
7.2.1-ogc4.1 and 6.18.48-ogc1.1: nothing without the symbol, `ntfs.ko` with `CONFIG_NTFS_FS=m`
on the make line. `source.env` carries the symbol as `KO_BUILD_ARGS`, `build-kmods.sh` refuses
a build that produced no file, and `55-ntfsplus.sh` asserts the `fs-ntfs` alias. `msi-ec` and
`acpi_ec` are immune, their fragments being unconditional `obj-m +=`.

## `mount -t ntfs` reaches the kernel driver only when no `mount.ntfs` helper exists

With the NTFSPLUS module loaded and `ntfs` in `/proc/filesystems`, `mount -t ntfs` still lands
on ntfs-3g and `findmnt` reports `fuseblk`: `mount(8)` hands any type with a
`/sbin/mount.<type>` helper to that helper before the kernel sees the type. The ntfs-3g package
links `mount.ntfs` and `mount.ntfs-fuse` to `mount.ntfs-3g` in both `/usr/bin` and `/usr/sbin`,
six links on the base (measured 2026-09-04). fstab rows, `.mount` units and `mount -t auto` go
the same way, libblkid reporting the type as `ntfs`. `mount -i` skips the helper and has no
fstab equivalent, which is why `55-ntfsplus.sh` removes the four generic links; `mount.ntfs-3g`
stays as the explicit FUSE route.

## A kernel module can pass vermagic and modinfo and panic at its first use

A build on a new kernel series shipped an NTFSPLUS pin that predated an iomap fix the module
needed under that series. The build and its vermagic guard were green, and every host with an
NTFS row in fstab kernel-panicked seconds after `Switching root`, before
`systemd-journal-flush`. The journal held nothing, pstore was empty, and the evidence lived on
the console alone (three panics, 2026-08-28). A build-time guard cannot catch this class, the
breakage being a runtime API mismatch and a real mount needing a booted target kernel. Every
pin bump therefore takes the runtime proof on a booted host, and `bazzite-mx-ntfsplus-setup
enable` runs that proof on a loop image before it rewrites a single fstab row.

## The two NTFS kernel drivers agree on modes and case, with two permissive exceptions

On a volume mounted `umask=000` the mode bits come from the WSL metadata EAs `$LXMOD`, `$LXUID`
and `$LXGID`, written by WSL and by both drivers, not from the mask: an object carrying
`$LXMOD` reports exactly that mode. `ntfs3` lets `$LXUID`/`$LXGID` override the mount's
`uid=`/`gid=`, where NTFSPLUS lets the mount option win. `ntfs3` also subtracts the write bits
for the DOS read-only attribute, where NTFSPLUS reads none at inode load. Both differences are
permissive-only, no object losing a bit, and the round trip is lossless. Both drivers mount
case-sensitive by default and accept `nocase`. Measured 2026-07-30 on a volume shared with
Windows, fresh mounts on both sides, a mount already up serving `$LXMOD` from the cached inode.
This is why the NTFSPLUS opt-in can rewrite an fstab row without touching its options
([`divergences.md`](divergences.md)).

## A local pre-flight can exit 0 without running a changed build script

buildah keys a `RUN` layer on its command string and its parent layer; the content behind a
`--mount=type=bind,from=ctx` is not hashed into it. After a change under `build_files/` or
`system_files/`, a pre-flight whose base layers are cached reports `Using cache` on the
kmod-builder and build steps and exits 0 in about three minutes with an image built from the
old scripts. Measured 2026-09-04: the closed flavour's pre-flight after a new feature printed
ten `Using cache` lines and no `kmod ntfsplus:` line, while `--no-cache` produced the real
build. CI is not affected, a fresh runner having no layer cache. `preflight-build.sh` judges
the exit status first, then refuses a log without the scripts' own output (`build.sh: N scripts
ran`, `tests: N passed`) as a cached build. The image id is no proof either way: the `LABEL`
layer carries a fresh `created` stamp, so the id changes on every run, cached or not (measured
2026-09-05: a fully cached run committed a new id).

## Parallel jobs on one self-hosted host collide in the shared home

Every instance of a self-hosted runner registered as the same user shares that user's home.
`cosign-installer` writes its binary to `$HOME/.cosign` by default, and a job running the
bootstrap cosign there while a sibling job downloads over it dies with
`./cosign: Text file busy` (exit 126). Measured 2026-09-05: the first main-profile run with
three instances active failed one of three build jobs on `Install cosign`; the two-instance
runs before it had passed. `reusable-build.yml` installs cosign under `${{ runner.temp }}`,
where the GHCR logins already live; anything else a job installs on the host goes the same
way.

## The OGC kernel's changelog is its git tag, not the RPM changelog

`rpm -q --changelog kernel` on the image prints one inherited Nobara entry from February 2026
and nothing else: OGC builds from stable tags in CI without a per-build changelog entry
(measured 2026-09-04 on `7.2.1-ogc4.1.fc44`). The real changelog is the mirror
https://github.com/OpenGamingCollective/linux, branch `ogc-<series>.y`, tagged `vX.Y.Z-ogcN`,
where an RPM release like `7.2.1-ogc4.1` is the tag `v7.2.1-ogc4` plus the RPM build number.
Two builds compare at `.../compare/<tagA>...<tagB>`. A `git log A..B` over that branch walks
into the merged `features/*` histories and reports tens of thousands of commits, so filter on
the OGC subject prefixes (`[FROM-ML]`, `[EXTERNALLY-MAINTAINED]`) instead. A stable bump
rebases the patchset unchanged, so the whole delta is upstream's; kernel config changes live in
the separate `kernel-packages` repository and never show in that diff.

## NTFSPLUS can refuse a directory entry with a bare `EINVAL`, once

On a volume under NTFSPLUS, `mkstemp` and `touch` in one directory failed with `Invalid
argument` while the kernel log carried the chain `ntfs_attr_add(): Failed to add resident
attribute`, `ntfs_ibm_add(): Failed to add AT_BITMAP`, `ntfs_ir_make_space(): Failed to modify
INDEX_ROOT` (measured 2026-08-04, kernel `7.1.5-ogc5.1`, a Windows system volume with 504 GB
free). Every tool reads the `EINVAL` as a bad name or an unwritable directory. The condition is
transient: the same directories accepted the same names the next day on the same mount, the WSL
metadata EAs made no difference, and the three files involved matched the source by checksum,
so nothing was truncated. Before chasing permissions or names, read `journalctl -k -g 'ntfs:
(device'` for the window; `rsync --inplace` skips the temporary file and goes through.
