# Gotchas

Surprises found on this project that a reader would otherwise rediscover the hard way. Each one
says what happens, how and when it was measured, and what the repository does about it. The
rules themselves live in [`conventions.md`](conventions.md).

Contents, in the order of the entries: torn writeback on 6.17-azure · just duplicate recipe ·
ujust.sh readonly names · kvmfr qemu.conf edit · kvmfr under sudo · grep -v on an empty set ·
command | grep -q · modinfo /lib/modules path · modprobe -n -v on a loaded module · podman
build labels · stub-resolv.conf left in the image · remove-unwanted-software v9 · skopeo and
containers-storage · workflow off the default branch · force-push without a push run ·
setup-oras versions · cosign verify and referrers · inactive package request · 1Password
BrowserSupport gid · local RPM blocks the rebase · EXIT trap and local · private install marker
· mise dotnet SDK · burnt immutable tag · rollback onto a pruned tag · blob/main link ·
ghcr-cleanup-action patterns · GHCR 5000-download limit · kbuild fragment compiles nothing ·
mount -t ntfs helper · module panics at first use · NTFS drivers' modes and case · udisks
defaults outside allow · pre-flight without the changed script · OGC kernel changelog ·
NTFSPLUS EINVAL · skel and existing accounts · KXmlGui write-back · flags in a command
substitution · findmnt --verify on nofail · fstab row ending at its type · fstab row with
leading whitespace · mount point with a space · status empty list · verify-host and unplugged
nofail · findmnt -t exit status · automount over autofs · root's flatpak list · SBOM media type
· image-info.json vs OCI label day · FAIL branch before its verdict · sunshine --version home ·
Docker FORWARD policy and libvirt · # inside an fstab field · 2> /dev/null on a failed
redirection · recipe description line · cosign 3.1.3 bundle flag · vendor build-log warnings ·
no BTF from kernel-devel · arithmetic error escapes set -e · scriptlet rewrote a .pyc ·
anonymous GHCR 403.

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

CI builds on `ubuntu-26.04` for this reason, and the image carries neither a cold NUL sweep nor
a fresh-inode helper. A runner whose kernel is a 6.17-azure brings the defect back.

## `just`: the earlier import wins on a duplicate recipe name

With `set allow-duplicate-recipes` and the same recipe name in two imported files, just keeps
the recipe of the file imported first (just manual, "Imports"; measured 2026-09-02 with two
files on just 1.57.0). An import appended after the base's files can never override a base
recipe, so `70-justfile.sh` replaces the base file or cuts the recipe out of it, and fails the
build on any name defined twice.

## `ujust.sh` declares its colour and formatting names readonly

`source /usr/lib/ujust/ujust.sh` brings `libcolors.sh` and `libformatting.sh`, which declare
`red`, `green`, `bold`, `normal` and the short forms `b` and `n` with `declare -r`
(ublue-os-just 0.57-3.fc44, measured 2026-09-06 on the hub). A script that assigns one of them
after the source prints `b: readonly variable` at every run and keeps the library's value;
under `set -e` it stops there. The kvmfr helper carried such a line, added on the belief that
`ujust.sh` left `b` and `n` unset; it is bazzite-dx's file again, a shellcheck directive
standing in for the assignment (the runner cannot follow the source), and
`tests/22-virtualization.sh` refuses any assignment to a name the libraries declare readonly,
the list read from the image and an empty list a failure.

## The kvmfr helper's `qemu.conf` edit matches nothing on this base

`bazzite-dx-kvmfr-setup` uncomments libvirt's default `cgroup_device_acl` with `/dev/kvmfr0`
appended by matching the whole commented block, `/dev/kvm` on its own line included. The
`/etc/libvirt/qemu.conf` of this image (libvirt of Fedora 44, measured 2026-09-06 in the
`44.20260906` release) lists `"/dev/ptmx", "/dev/userfaultfd"` with no `/dev/kvm`, so the
substitution changes nothing and prints nothing: the step ran, the file stayed as it was. The
rewrite of 2026-09-06 kept the edit as upstream wrote it; on 2026-09-14 the step was dropped
instead, a call that writes nothing on every host this image reaches being one step of a recipe
that lies about what it did. A libvirt whose commented block matches upstream's again would
need the edit back, with the block re-read at that point.

## The kvmfr helper runs under sudo, so `$HOME` and `$USER` are root's

`ujust setup-virtualization` calls `sudo /usr/libexec/bazzite-dx-kvmfr-setup`, the line
upstream's recipe has (`bazzite-dx`, `84-bazzite-virt.just`), while the helper still calls sudo
on each root step, as upstream's does. The image's `/etc/sudoers` carries
`Defaults always_set_home` and keeps `HOME` out of `env_keep` (measured 2026-09-08 in the
`44.20260908.dev` pre-flight image), so inside the helper `HOME=/root` and `USER=root`: the
SELinux policy lands under `/root/.config/selinux_te/`, a path the helper prints to the user
who cannot read it, and the final `chown "$USER:qemu" /dev/kvmfr0` gives the device to root.
Kept as upstream wrote it (the port is by design faithful); a fix is a behaviour change.

## `grep -v` on an empty set kills a `pipefail` script silently

`... | grep -v '^$' | ...` exits 1 when no line survives the filter, and under
`set -euo pipefail` the script dies without a message (measured 2026-09-02 in `00-prep.sh`,
first pre-flight of the justfile feature). `sed '/^$/d'` exits 0 on an empty set and is what
`recipe_set` uses in `lib/just.sh`. A dry run in a container without `set -e` had not caught
it, dry runs carrying `set -euo pipefail` too.

## `command | grep -q` under `pipefail` fails on a match

`grep -q` exits at the first match and closes the pipe; a writer still producing output dies of
SIGPIPE, the pipeline's status is 141 and `pipefail` reports a failure. Measured 2026-09-02: a
helper's `status | grep -q` turned a passing check red during the pre-flight of the
kernel-modules feature. Capture the output in a variable, then grep the variable. The shape can
pass for months and fail on a base change: `tests/95-clean-stage.sh` read the kernel lock
through `dnf5 versionlock list | grep -q` and was green while the list held five entries; the
base of 2026-09-07 (`44.20260907`, kernel 7.2.3-ogc3.1) locks every qt6 and plasma package too,
the list runs to 3179 lines, and the three flavours went red on `tests: FAILED` with a
docs-only change (measured 2026-09-07, status 141 reproduced in the base). The test captures
the list first. The same day the release run went red on `rpm -q gpg-pubkey | grep -qi` in
`tests/30-ide.sh`, five lines of output, on a base the main run had passed minutes earlier: in
the base's container the pipe failed 16 times in 1000 runs. Every `| grep -q` of the repo
captures first and `check-form.sh` refuses the shape.

## `modinfo -F filename` and `modprobe --show-depends` print `/lib/modules/...`

The module tools print the legacy path even when the file lives under `/usr/lib/modules`
(`/lib` being a symlink to `usr/lib`), so a literal string comparison against the staged path
fails (measured 2026-09-02). `50-kmods.sh` and `55-ntfsplus.sh` compare `realpath` of the
resolved module against `realpath` of the file they installed.

## `modprobe -n -v` is silent for a loaded module; `--show-depends` is not

The two dry runs answer different questions. Measured 2026-09-06 on the hub, kmod 34.2 on
`7.2.1-ogc4.1.fc44`, the blacklist masked with `-C /nonexistent`:

| `ntfs` module | blacklisted, `-n -v` / `--show-depends` | free, `-n -v` / `--show-depends` |
| ------------- | --------------------------------------- | -------------------------------- |
| not loaded    | nothing / nothing                       | `insmod` / `insmod`              |
| loaded        | nothing / nothing                       | nothing / `insmod`               |

`-n -v` says whether modprobe would do anything now, so a loaded module reads like a
blacklisted one; `--show-depends` says whether the alias resolves, and honours the blacklist
too. `ntfs_alias_resolves` in `bazzite-mx-ntfsplus-setup` (then `alias_resolves`) used `-n -v`
and read a working opt-in as a failed mask on every host whose driver was already loaded: on
the desktop, opt-in active and four volumes mounted, it returned 1 with an empty dry run
(measured 2026-09-06). The function reads `--show-depends` after the captured configuration.
The note of 2026-09-05 that `--show-depends` printed `insmod` through an active blacklist did
not reproduce in any cell of the table. The same probe once read the blacklist through
`! modprobe -c | grep -q`, the SIGPIPE shape of § `command | grep -q` under `pipefail` fails on
a match above on a 2 MB config, so its negation was never false: the config is captured first.

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
2026-09-02). Every `RUN` of the image stage therefore mounts a tmpfs on `/run`; the build and
the tests mount one on `/tmp` too. `bootc container lint` cannot see them from inside a
container, where podman fills `/run` itself, so `check-image.sh` reads both directories on the
mounted image instead.

## `ublue-os/remove-unwanted-software` v9 fails on `ubuntu-26.04`

Its apt step runs `apt-get remove -y powershell --fix-missing` and the 26.04 runner image has
no such package: `E: Unable to locate package powershell`, exit 100, the job dead before the
build (measured 2026-09-02). The `df` the action prints first showed 92 GB free of 145 GB on
that runner, so the image build, the compose archive and the chunked pull fit without freeing
anything. The action is not used. image-template pins commit `695eb75b` of the action, the
`v10` merge without the apt step, which has no release tag.

## `skopeo` cannot read `containers-storage:` in a runner job

`skopeo inspect containers-storage:<image>` in a rootless job on `ubuntu-26.04` dies with
`Error during unshare(...): Operation not permitted` (measured 2026-09-02): skopeo needs a user
namespace of its own to open podman's rootless storage and the runner denies it to that binary,
while podman itself works. What a step needs from a local image is read with
`podman image inspect`; skopeo is used on `docker://` references only.

## A workflow that is not on the default branch has no runs endpoint

`gh run list --workflow release.yml` and the API path
`GET /repos/{owner}/{repo}/actions/workflows/release.yml/runs` answer
`HTTP 404: workflow release.yml not found on the default branch` while the file exists only on
a branch (measured 2026-09-02). `gh workflow run release.yml --ref <branch>` resolves the file
the same way. Runs of such a workflow are read from the repository-wide endpoint filtered on
`.path` (`watch-upstream.sh`), and a workflow is dispatched on a branch only once its file is
on the default branch too.

## A force-push of a rewritten history may create no `push` run

Force-pushing a branch onto a head that shares no ancestor with the previous one created no run
of `build.yml`, while the same workflow file dispatched fine on that ref (measured 2026-09-02:
no run listed six minutes after the push; none again on 2026-09-05 at 20:01Z and on 2026-09-06
at 23:35Z). A path filter is a two-dot diff of the pushed head against the previous head, and
GitHub documents the empty case ("Workflow syntax", `on.push.paths`: "If there are no files
changed, the workflow will not run"). The same shape of push did create the `push` runs once on
2026-09-05 and twice on 2026-09-06, so the rule is not one to rely on either way. After such a
push the run list is read before anything is assumed, and what is missing is dispatched by
hand, `gh workflow run build.yml --ref <branch>`, and `deploy-pages.yml` likewise.

## `setup-oras` installs only the ORAS versions embedded in its own release

`oras-project/setup-oras` v2.0.1 resolves `version` against a list shipped in the action,
`src/lib/data/releases.json`, which runs from 1.0.0 to 1.3.3 (re-read 2026-09-06 at v2.0.1).
Any other version fails with "official ORAS CLI releases does not contain version 1.3.4"
(measured 2026-09-03, after the push and the signature of `:staging`). v2.0.2 added 1.3.4 on
2026-09-29, 33 days after ORAS released it (read 2026-10-01). `install-oras.sh` installs from
the ORAS release directly, the tarball refused unless its sha256 matches the release's
checksums file.

## `cosign verify --key` reads a certificate-signed referrer before the `.sig`

`ghcr.io/ublue-os/bazzite:stable` carries its legacy `.sig` tag, an SPDX SBOM and a SLSA
provenance bundle, the last two attached as OCI referrers. cosign v3.1.3
`verify --key cosign.pub` on it fails with "no matching attestations: expected key signature,
not certificate" and never reaches the `.sig`: the provenance bundle is signed with a
certificate and a key was requested. An image of ours, checked with a throwaway key, fails
instead with "no matching signatures: error verifying bundle: comparing public key PEMs".
Measured 2026-09-03 locally with the same cosign as the gate, after a negative control that
accepted only the second shape stopped a release run as inconclusive. `cosign_rejected` in
`gate-release.sh` classifies both shapes as rejections of the signing material and leaves the
transport errors inconclusive.

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
31001/31002) and by the Gentoo overlays that carry `acct-group/onepassword` (gentoo-zh at 26753
after a first `-1` broke the browser integration, nekochigura refusing a gid under 1000; read
2026-09-06); `40-desktop-apps.sh` creates the two groups with the fixed gids 31001 and 31002.

## A local RPM the new image ships blocks the rebase; a repository package does not

A host carrying 1Password 8.12.28 as a local package (`rpm-ostree install ./1password.rpm`)
cannot upgrade onto an image that ships 8.12.34: the depsolve fails with "cannot install both
1password-8.12.28-1.x86_64 from @commandline and 1password-8.12.34-1.x86_64 from @System:
conflicting requests" (measured 2026-09-04 on two hosts). The same package layered from the
vendor repository rebases through and leaves an inactive request. A repository request is
re-resolved against the new base, where a local one is the file itself.
`rpm-ostree upgrade --uninstall=<nevra>` drops the request in the same transaction
([`migration.md`](migration.md)).

## An EXIT trap cannot read a `local` of the function that armed it

`bazzite-mx-migrate apply` kept `timer_was_active` as a `local` of `cmd_apply` and armed
`trap restore_timer EXIT` from there. The trap runs after the function has returned, the local
is gone, and under `set -u` bash dies with "timer_was_active: unbound variable" once every step
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
pointed elsewhere. `ujust setup-dev help` says so; the other runtimes stay under `installs/`.

## A deleted immutable release keeps its tag name burnt

With immutable releases on (the repository setting in [`workflow.md`](workflow.md)), a tag name
that ever carried a published release is refused for good: `gh release create` answers
`HTTP 422 … tag_name was used by an immutable release`, and so does `POST /git/refs` for a bare
tag, with the setting switched off as well. Measured 2026-09-05 after
`gh release delete 44.20260905 --cleanup-tag`: the rebuilt release run promoted its three
images to GHCR as `44.20260905` and died in the release job; the retry with the setting off
died the same way. `release-tag.sh` probes GHCR and the release list, neither of which lists a
burnt name, so the rule is procedural: a release is never deleted to reuse its name; the next
release takes the next free name (`.N`, or the next day), or the name the dispatch forces with
`release_tag` ([`workflow.md`](workflow.md)). `clean.yml` prunes GHCR versions, whose names
come back. Measured 2026-09-06 22:18Z, every release, tag, GHCR version and run deleted: the
version job refused to pick a tag from an empty registry
(`no tag found … refusing to pick a tag`), which is why an empty answer counts as "nothing
taken" and only a failed probe stops it.

## A rollback deployment whose origin tag was pruned from GHCR boots but never updates

`ujust migrate apply <tag>` and a `bootc switch` onto a dated tag write that tag into the
deployment's origin. Once `clean.yml` or a cleanup by id has removed the tag from the package,
the deployment still boots, its commit being local, and `bootc upgrade` on it finds nothing to
pull: the host reports the rollback as healthy and stale at the same time. Measured 2026-09-04
on a laptop whose rollback carried `44.20260904.2` after that tag was deleted; the deployment
went away with the next upgrade of the booted one, which is the only thing a dated origin
needs. `verify-host` reads the booted deployment only: a rollback on a dated tag shows in
`rpm-ostree status` and nowhere else.

## A `blob/main` link is dead until the file is on `main`

`https://github.com/<owner>/<repo>/blob/main/<path>` and the raw form answer 404 while `<path>`
exists only on a branch (measured 2026-09-02 on the home page's link to `docs/migration.md`, a
file not yet on `main`). `check-site.sh` resolves such links on the checkout instead of
fetching them, so the page and the file it points at ship in the same push.

## `ghcr-cleanup-action` matches `packages` by pattern only with `expand-packages`

`use-regex: true` reaches `delete-tags` and `exclude-tags`; `packages` stays a comma-separated
list of literal names unless `expand-packages: true`, which a wildcard character in the value
switches on by itself, and which lists the owner's packages through the Packages API and
requires a classic PAT (`src/main.ts` and `src/config.ts` at v1.2.2, read 2026-09-02 and again
2026-09-06; `GITHUB_TOKEN` is refused there). With `expand-packages` and `use-regex`, the whole
`packages` string is one regular expression, not a list of them. `clean.yml` names the three
packages one by one.

## A GHCR version with more than 5000 downloads cannot be deleted

`DELETE /user/packages/container/<package>/versions/<id>` answers HTTP 400 for a version of a
public package that has been pulled more than 5000 times (GitHub docs, "Deleting and restoring
a package": such a version is deleted by GitHub support only). Measured 2026-09-06 while
emptying the three packages by hand: 15 of 18 versions went, the 3 refused ones being the
untagged manifests every host had pulled as `:stable`. They carry no tag and no host reaches
them by name; a cleanup reports the refusal and goes on, and they stay where they are.

## A kbuild fragment gated on a kernel config symbol compiles nothing and exits 0

`make -C /usr/src/kernels/<kver> M=<clone> modules` on `namjaejeon/linux-ntfs` prints
`MODPOST Module.symvers`, exits 0 and produces no `.ko`. Its fragment is
`obj-$(CONFIG_NTFS_FS) += ntfs.o`, which expands to `obj- += ntfs.o` against a kernel that
leaves the symbol unset, a variable kbuild never reads. The module's own top-level `Makefile`
hides this with `export CONFIG_NTFS_FS := m`, which a direct `-C <kernel> M=` call bypasses.
Measured 2026-09-04 on 7.2.1-ogc4.1 and 6.18.48-ogc1.1: nothing without the symbol, `ntfs.ko`
with `CONFIG_NTFS_FS=m` on the make line. `source.env` carries the symbol as `KO_BUILD_ARGS`,
`build-kmods.sh` refuses a build that produced no file, and `55-ntfsplus.sh` asserts the
`fs-ntfs` alias. `msi-ec` and `acpi_ec` are immune, their fragments being unconditional
`obj-m +=`.

## `mount -t ntfs` reaches the kernel driver only when no `mount.ntfs` helper exists

With the NTFSPLUS module loaded and `ntfs` in `/proc/filesystems`, `mount -t ntfs` still lands
on ntfs-3g and `findmnt` reports `fuseblk`: `mount(8)` hands any type with a
`/sbin/mount.<type>` helper to that helper before the kernel sees the type. The ntfs-3g package
links `mount.ntfs` and `mount.ntfs-fuse` to `mount.ntfs-3g` in `/usr/bin`, also reached as
`/usr/sbin`, a link to `bin` (measured 2026-09-04). fstab rows, `.mount` units and
`mount -t auto` go the same way, libblkid reporting the type as `ntfs`. `mount -i` skips the
helper and has no fstab equivalent, which is why `55-ntfsplus.sh` removes the two generic
links; `mount.ntfs-3g` stays as the explicit FUSE route.

## A kernel module can pass vermagic and modinfo and panic at its first use

A build on a new kernel series shipped an NTFSPLUS pin that predated an iomap fix the module
needed under that series. The build and its vermagic guard were green, and every host with an
NTFS row in fstab kernel-panicked seconds after `Switching root`, before
`systemd-journal-flush`. The journal held nothing, pstore was empty, and the evidence lived on
the console alone (three panics, 2026-08-28). A build-time guard cannot catch this class, the
breakage being a runtime API mismatch and a real mount needing a booted target kernel. Every
pin bump therefore takes the runtime proof on a booted host, and
`bazzite-mx-ntfsplus-setup enable` runs that proof on a loop image before it rewrites a single
fstab row.

## The two NTFS kernel drivers agree on modes and case under a mask, with permissive exceptions

On a volume mounted `umask=000` the mode bits come from the WSL metadata EAs `$LXMOD`, `$LXUID`
and `$LXGID`, written by WSL and by both drivers, not from the mask: an object carrying
`$LXMOD` reports exactly that mode. `ntfs3` lets `$LXUID`/`$LXGID` override the mount's
`uid=`/`gid=`, where NTFSPLUS lets the mount option win. `ntfs3` also subtracts the write bits
for the DOS read-only attribute, where NTFSPLUS reads none at inode load. Both differences are
permissive-only, no object losing a bit, and the round trip is lossless. Both drivers mount
case-sensitive by default and accept `nocase`. Measured 2026-07-30 on a volume shared with
Windows, fresh mounts on both sides, a mount already up serving `$LXMOD` from the cached inode.
Without `umask`, `fmask` or `dmask` they part: `ntfs3` masks with the umask of the mounting
process (0022 under systemd), NTFSPLUS with none, so an object without `$LXMOD` is 0755 under
`ntfs3` and 0777 under NTFSPLUS, writable by every account. Measured 2026-10-01 on a row
`uid=1000,gid=1000`, the defaults read in each driver's `super.c`. This is why the NTFSPLUS
opt-in can rewrite an fstab row that carries a mask without writing one
([`divergences.md`](divergences.md)).

## A udisks `_defaults` option its `_allow` set lacks fails every mount

`/etc/udisks2/mount_options.conf` replaces each builtin set of udisks whole, key by key. A file
with only `ntfs:ntfs_defaults` extended by `errors=remount-ro` made udisks refuse every
NTFSPLUS mount with ``Mount option `errors=remount-ro' is not allowed``; with `ntfs:ntfs_allow`
extended too, NTFSPLUS mounted the volume `errors=remount-ro`, and without the file
`errors=continue`. Measured 2026-10-02 with udisks2 2.11.2 in a privileged container of the
image, the host's udev shared, on a 64 MB loop image formatted by `mkntfs`. The image's file
carries both keys ([`divergences.md`](divergences.md) § NTFSPLUS as a per-host opt-in).

## A local pre-flight can exit 0 without running a changed build script

buildah keys a `RUN` layer on its command string and its parent layer; the content behind a
`--mount=type=bind,from=ctx` is not hashed into it. After a change under `build_files/` or
`system_files/`, a pre-flight whose base layers are cached reports `Using cache` on the
kmod-builder and build steps and exits 0 in about three minutes with an image built from the
old scripts. Measured 2026-09-04: the closed flavour's pre-flight after a new feature printed
ten `Using cache` lines and no `kmod ntfsplus:` line, while `--no-cache` produced the real
build. CI is not affected, a fresh runner having no layer cache. `preflight-build.sh` judges
the exit status first, then refuses a log without the scripts' own output
(`build.sh: N scripts ran`, `tests: N passed`) as a cached build. The image id is no proof
either way: the `LABEL` layer carries a fresh `created` stamp, so the id changes on every run,
cached or not (measured 2026-09-05: a fully cached run committed a new id).

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

On a volume under NTFSPLUS, `mkstemp` and `touch` in one directory failed with
`Invalid argument` while the kernel log carried the chain
`ntfs_attr_add(): Failed to add resident attribute`, `ntfs_ibm_add(): Failed to add AT_BITMAP`,
`ntfs_ir_make_space(): Failed to modify INDEX_ROOT` (measured 2026-08-04, kernel
`7.1.5-ogc5.1`, a Windows system volume with 504 GB free). Every tool reads the `EINVAL` as a
bad name or an unwritable directory. The condition is transient: the same directories accepted
the same names the next day on the same mount, the WSL metadata EAs made no difference, and the
three files involved matched the source by checksum, so nothing was truncated. Before chasing
permissions or names, read `journalctl -k -g 'ntfs: (device'` for the window; `rsync --inplace`
skips the temporary file and goes through.

## A skel file reaches no account that already exists

`/etc/skel` is read once, by `useradd`, when it creates a home (useradd(8), `-k`). The Konsole
`sessionui.rc` and the PowerShell profile shipped there since the first image were absent from
every home of the three hosts that run it (measured 2026-09-07, `test -f` on each), while the
two Plasma update scripts of the same feature had run, plasmashell replaying them per user. The
docs said the four defaults reach existing accounts alike. The user hook
`12-bazzite-mx-copy-paste.sh` copies the two files at login when they are missing, the way
`11-bazzite-mx-vscode-extensions.sh` seeds `settings.json`; a skel file added later needs the
same.

## KXmlGui writes the merged file back at the application's version

The Konsole shortcut file ships with `version="1"` so that KXmlGui merges its
`ActionProperties` into Konsole's own layout. At Konsole's next start the local file is
rewritten as the full merged layout at Konsole's version, the `ActionProperties` kept (measured
2026-09-07: 668 bytes seeded, 3812 bytes and `version="36"` after one start). The shortcut
holds; a reader comparing the home copy with the skel copy finds them different.

## A step run in a command substitution sets its flags in a subshell

`bazzite-mx-migrate apply` called step 2 as `backup=$(step_2_backup_pin_and_stop_timer)` to
read the backup directory it printed. The step also set `TIMER_WAS_ACTIVE=1` after stopping
`uupd.timer`, and that assignment stayed in the subshell: the EXIT trap read 0 and never
started the timer again. Measured 2026-09-07 in a VM on the first `apply` whose step 2 ran in a
command substitution, `uupd.timer` inactive after every exit path; the earlier self-test preset
the flag and could not see it. The step sets `BACKUP` and the flag as globals and is called
plainly, and the self-test refuses a `=$(step_2_` in the source.

## `findmnt --verify` reports an unplugged `nofail` volume as an error

A `nofail` row whose UUID is absent, the external disk that is not plugged in, gets
`[E] unreachable on boot required source` from `findmnt --verify`, and exit status 1, the
option notwithstanding (measured 2026-09-07, util-linux of Fedora 44, in a VM with such a row
on the `ntfs` driver). `bazzite-mx-migrate apply` ran the verification after writing the
rewritten table and treated the status as fatal: the run stopped at step 6 with the `ntfs3` row
already written, step 6b and 7 never ran. `bazzite-mx-ntfsplus-setup enable` and `disable` had
the same shape: the table written, then `findmnt --verify --fstab` fatal, the remount never
reached, so a host with such a row was left with its rows switched and its volumes on the old
driver. Both helpers verify the rewritten table before writing it, through `--tab-file`, and
stop only on an error the current table does not already carry (`host.sh`, shared); the
messages are read under `LC_ALL=C`, findmnt localizing them. The verdict is the summary line
findmnt ends with, never the presence of output: on a table with a row of fewer than three
fields findmnt prints `parse error at line N -- ignored` and dies of SIGSEGV, status 139, with
no summary (measured 2026-09-07, util-linux 2.41.5), and a probe keyed on "printed anything"
read that as a clean table; a table without the summary is refused, nothing written. The two
streams have to be merged, and findmnt block-buffers its findings on stdout into a pipe while
the summary on stderr is not buffered: past 4096 bytes of findings the summary lands inside a
cut line, whose tail starts at column 0 and passes for a mount point, so before and after the
rewrite the sets differed and a legitimate rewrite of a 28-row table was refused (measured
2026-09-07 in the build image). The helpers run findmnt under `stdbuf -oL`, and the self-test
of `bazzite-mx-migrate` carries a 40-row table.

## A fstab row may end at its type

fstab(5) makes the fourth, fifth and sixth fields optional, so `UUID=… /mnt/data ntfs` is a row
`findmnt --verify` parses and the helpers count. Both rewriters required a blank after the type
and left such a row alone, and the guard on rows left then refused the table for good:
`ujust setup-ntfsplus disable`, the documented recovery, could not run on that host (measured
2026-09-07 in the build image). The rewriters accept the end of the row after the type, and
both self-test tables carry a row of that shape.

## A fstab row may start with whitespace

libmount skips the blanks before the first field, so `   UUID=… /mnt/data ntfs3 …` is a row
`findmnt --tab-file` lists and the helpers' awk counts, but the two rewriters anchored their
pattern at a non-blank byte and left it alone; the guard on rows left then refused the table
for good, `disable` and step 6 of `migrate` included (measured 2026-09-08 in the build image).
The pattern allows leading blanks, kept as they are, and both self-test tables carry an
indented row. A CRLF table is the sibling case: the rewriters treat `\r` as the blank after the
type and switch the column, but awk's default splitting does not, so a row ending at its type
read as type `ntfs\r` and never reached the remount; `fstab_entries` drops a trailing `\r`
(measured 2026-09-08 on a scratch table).

## A mount point with a space was never remounted

`setup-ntfsplus` handed the mount points of the rewritten rows to `umount`, `mount` and
`findmnt --mountpoint` as fstab writes them, so `/mnt/games\040disk` matched nothing, the
`continue` for an unmounted volume fired and the volume stayed on the old driver with no line
printed; `verify-host`, which unescapes, then failed the row as mounted with the other type
(measured 2026-09-08 with a bind mount on a path with a space). The loop unescapes each point
first (`unescape_fstab_field`, `host.sh`), and the self-test stubs `umount` and `mount` to read
the paths they receive.

## `status` printed an empty list for a type with no row

`setup-ntfsplus status` printed `fstab ntfs3: ` for a type with no row: the `none` substitution
was a `sed` on the list, which runs on zero lines and prints nothing (measured 2026-09-07). It
is a parameter default, and the self-test checks the three lines on a table without NTFS rows;
`mounted:` gets the same `none` when `findmnt` lists nothing.

## `verify-host` read an unplugged `nofail` volume as a mount failure

`check_fstab_row` judged a row by its mount alone: an NTFS row whose volume was not mounted got
`FAIL: fstab: <target> is <type> but not mounted (dirty volume? …)` whether the device was
there or not, so a host with an external disk unplugged could never pass (measured 2026-09-07
in the VM of the `migrate` proof, with a `nofail` row on an absent UUID). The check resolves
the row's source first (findfs(8) for `UUID=`, `LABEL=`, `PARTUUID=`, `PARTLABEL=`, the path
itself otherwise): device present and not mounted stays the FAIL, device absent is `INFO` when
the row has `nofail` and a FAIL naming the device when it has not; a `noauto` row is `INFO`,
and a row with `x-systemd.automount` is OK with `autofs` at its target or, once triggered, with
the volume's type on top of it (§ A triggered automount stacks the volume's type over
`autofs`). fstab(5) writes a space as `\040` and findfs(8) does not unescape it
(`LABEL=New\040Volume` is "unable to resolve" while `LABEL=New Volume` resolves, measured
2026-09-07 on a real label), so the fields are unescaped first, a backslash and exactly three
octal digits and nothing else: bash's `printf '%b'` also reads `\0401` as one byte, `\x20` and
`\c`, which libmount does not (measured the same day against `findmnt --tab-file`). findfs's
"unable to resolve" is the only answer read as absent, any other failure stopping the helper
with exit 1, its `ERROR:` line naming the source, an unreadable probe being no proof of
absence.

## `findmnt -t` exits 1 on any error and 0 with nothing on no match

`src_ntfs_mounts` of `bazzite-mx-ntfsplus-setup` read a non-zero
`findmnt -t ntfs,ntfs3,fuseblk` as "no volume mounted", so a table findmnt could not read
passed as an unmounted host (`mounted: none`, exit 0). Measured 2026-09-10 in the image
(util-linux 2.41.5): with no matching row findmnt exits 0 and prints nothing, and it exits 1 on
every error, a bad option, an absent or unreadable table, an unknown column. A non-zero status
is an error, ended with `ERROR:`; the self-test feeds a stub that exits 1 (refused) and one
that exits 0 with nothing (the empty list).

## A triggered automount stacks the volume's type over `autofs`

A fstab row with `x-systemd.automount` mounts `autofs` at its target; the first access mounts
the volume over it and `findmnt -n -o FSTYPE <target>` lists both, `autofs` then the volume's
type, one per line. `mount_fstype` of `host.sh` returned the two lines as one value, so
`verify-host` printed a FAIL with a bare line for a triggered row (measured 2026-09-10 on a
triggered `ntfs3` row). Both code paths take the last line, the top of the stack, and
`tests/helpers/verify-host.sh` proves it on a triggered `/mnt/auto2` next to the untriggered
one.

## Root's `flatpak list` misses the invoking user's installation

`ujust verify-host` runs its helper through sudo, and `flatpak list` as root lists the system
installation and root's own user one: the user who typed the recipe has a user installation of
their own that root never sees (measured 2026-09-12 on the hub: 43 apps for the user, 41 for
root, the two user-scope ones missing). A `flatpak install --user org.mozilla.firefox`
therefore passed as "no Firefox Flatpak" and the profile copy docs/migration.md asks for was
never announced. `src_flatpaks` lists `--system` as root and `--user` through
`runuser -u "$SUDO_USER"`, each status kept.

## The SBOM referrer is syft JSON under the SPDX media type

`reusable-build.yml` writes the SBOM with `syft -o syft-json` and attaches it with
`--artifact-type application/vnd.spdx+json`, the shape of `ublue-os/bazzite`'s build.yml
(`Generate SBOM` and `Upload SBOM` steps), and `changelog.sh` and site/verify.html select the
referrer by that type. The document is syft's own format (`{"artifacts": […]}`, no
`spdxVersion`; syft calls its media type `vnd.syft+json`), so an SPDX parser does not open the
file a reader pulls by following the type. Measured 2026-09-12 on `:stable` with
`oras discover` and `oras pull`. Kept as upstream's shape on purpose: verify.html says the
document is syft JSON, and the diff `changelog.sh` prints reads `.artifacts[]`.

## The base's image-info.json and its OCI label can name different days

`ghcr.io/ublue-os/bazzite@sha256:437920ba…` carries
`org.opencontainers.image.version=44.20260908` and ships an `image-info.json` whose `version`
is `44.20260907`. `resolve-base.sh` reads the label, so the `.dev` version of a sandbox build
follows it (a release tag is the run's UTC date, `release-tag.sh`), while `10-image-info.sh`
reads the file, so `base-version` and the `(Bazzite …)` of `version-pretty` follow the file: an
image built from that base is `44.20260908.dev (Bazzite 44.20260907)`, and a `.dev` build
without `VERSION` would be `44.20260907.dev`. Measured 2026-09-12 on the pre-flight image. Both
numbers are the base's own; the image reports each from its source and neither is rewritten.

## A FAIL branch died before its verdict

Six smoke tests, at eight sites, built their `FAIL:` line as
`lines=$(grep … "$file" | tr '\n' ' ')`: with the file empty, grep matched nothing and exited
1, `pipefail` failed the assignment, `set -e` ended the test before its `echo`, and the runner
saw a test that stopped early instead of the line naming the file (measured 2026-09-08 with an
empty `vscode.repo` mounted over the image: 2 lines of output instead of 11, no `FAIL:`). The
sibling shapes turned up one file at a time: `$(cmd || echo x)` under a command that prints its
answer and exits non-zero (`grep -c` printed `0`, then `echo` printed another), a `head -n1` on
a tool that prints several lines, `$(cmd)` inside an `echo` whose status nobody reads, an empty
variable printed as a value, a fixture file read as empty when missing, a state change inside
`if …; then` without an `else`. The two shapes a regex can see are rules 8 and 9 of
`check-form.sh` since 2026-09-08; the rest is read by hand at review, listed here for that
reading. One more shape has no pipe for rule 9 to see: a bare `var=$(jq …)`, `var=$(rpm -q …)`,
`var=$(tail …)` or `var=$(a_function)` whose command exits non-zero on the state the test is
there to catch (measured 2026-09-08: a master justfile that does not parse left `tests/70` at 3
lines of 80, an unreadable `image-info.json` left `tests/10` at none). A probe assigned in a
test carries `|| true` and its `FAIL:` line prints the fallback; the twenty sites of the tests
were converted the same day.

## `sunshine --version` needs a home directory

Sunshine 2026.906.222525 (released 2026-09-06) creates `$HOME/.config/sunshine` in
`config::parse` before it prints anything, `--version` included, and aborts with SIGABRT on an
uncaught `std::filesystem` exception when it cannot; 2026.516.143833 printed first. In the
build container `HOME` is `/root`, a link to `/var/roothome` that the image does not carry, so
the `41-sunshine` smoke test went red on the day the release landed (measured 2026-09-07, gdb
backtrace in the failed layer; `HOME=/tmp` printed the version). The test lends the binary a
temporary home; a booted host has one.

## Docker's `FORWARD` policy cuts libvirt's NAT guests off

A guest on libvirt's `default` network pinged `192.168.122.1` and nothing beyond, and
`curl https://ghcr.io/v2/` timed out (measured 2026-09-07 on a host running the image, Docker
CE 29.8.0 with its iptables backend, libvirt 12.0.0 with its nftables backend, firewalld off;
the probe was a network namespace on a veth attached to `virbr0`, the forwarding path of a
tap). libvirt's `ip libvirt_network` table accepts the guest's packets in its own `forward`
chain; the packet then traverses Docker's `ip filter` `FORWARD` chain, whose policy dockerd set
to `DROP` when it enabled forwarding, and no rule there matches a `virbr0` packet: an accept in
one nftables base chain is not final for the others. Docker evaluates `DOCKER-USER` first and
never flushes it, so `iptables -I DOCKER-USER -i virbr+ -j ACCEPT` and its `-o` twin restore
the route at once, and they survived `systemctl restart docker`. That pair also skips Docker's
own ingress rules in the filter table for every container; the image ships a narrower chain,
`BAZZITE-MX-LIBVIRT`, built by `bazzite-mx-libvirt-forward` from a `docker.service` drop-in
after dockerd is ready ([`divergences.md`](divergences.md) § Virtualization and quickemu).
Docker 29.8.0 protects a running container on its own as well: its `raw` table drops every
packet to the container's address that does not enter through `docker0` (one rule per
container, published ports or not, gone when the container stops), so a guest reaches a
container only through a port published on the host whatever the filter table says (measured
the same day: the guest got http 200 on the published port, nothing on the container's address,
with either form). No upstream image carries a counterpart (`git grep DOCKER-USER` empty in
bazzite, bazzite-dx, aurora and amyos).

## A `#` inside an fstab field is not a comment

Only a `#` that is the first non-blank character of a line opens a comment for libmount, so
`LABEL=Disco#2 /mnt/Disco2 ntfs defaults 0 0` is a row `findmnt --verify --tab-file` parses
with no parse error and `findmnt --tab-file -o SOURCE,TARGET,FSTYPE` lists (measured 2026-09-12
on a scratch table, util-linux 2.41.5). Both rewriters anchored their source field at
`[^#[:space:]]+`, which matches no field carrying a `#`, so such a row kept its type, the guard
on rows left refused the table, and `migrate apply` stopped in step 6, after the pin and the
`uupd.timer` stop, with no reason the user could act on. The pattern excludes `#` only as the
first character of the field, `[^#[:space:]][^[:space:]]*`, and both self-tests carry a row
whose label holds a `#` next to a commented-out row that would otherwise match. Windows volumes
reach the state: a `#` is legal in an NTFS label.

## A trailing `2> /dev/null` does not silence a failed redirection

Redirections are applied left to right and a `>` that fails ends the command there, so bash
reports the error before a `2> /dev/null` further right has been applied. `write_opt_in` of
`bazzite-mx-ntfsplus-setup` carried `ntfsplus_optin_text > "$NTFSPLUS_OPTIN.new" 2> /dev/null`
and leaked for that reason: as `nobody` under `LC_ALL=it_IT.UTF-8` it printed
`bash: riga 11: /etc/modprobe.d/bazzite-mx-ntfsplus.conf.new: Permesso negato` above its own
`ERROR:` line (measured 2026-09-12 in the pre-flight image). `2> /dev/null > file` is the order
that silences it, and on the same run the `ERROR:` line stood alone. Both sites read that way:
`write_opt_in` and `write_modules_load_file` of `bazzite-mx-msi-setup`.

## A recipe's description is the LAST comment line above it

`just --list`, which `ujust` runs, shows one description per recipe and takes it from the last
comment line above the recipe, not from the whole comment block. Measured 2026-09-12 with just
1.57.0: a two-line comment lists as `foo # second line of the description`, the first line
lost. So the description comments of `82-bazzite-sunshine.just` (113 columns) and
`95-bazzite-mx.just` (102 columns) stay on one line: wrapping them to the 100 columns of
`docs/conventions.md` § Form would silently cut what a user reads in `ujust`. `.just` files are
outside the shell catalogue `check-form.sh` measures, so nothing enforces the limit there
anyway.

## cosign 3.1.3 deprecates the flag the signature layout needs

`cosign sign -y --new-bundle-format=false --use-signing-config=false <ref>` opens with "Flag
--new-bundle-format has been deprecated, this will be the only supported format in future
versions" (measured 2026-09-12 with the pinned cosign v3.1.3). The flag still works and
`reusable-build.yml` and `sign-image.yml` need it off: the new bundle format is not the layout
`policy.json`'s `sigstoreSigned` reads on a host (containers/container-libs#388,
coreos/rpm-ostree#5509). The release that removes it signs images a host cannot verify, and
`refresh-pins.sh --apply` would carry the pin past it with an `OK` row, reading the tag alone.
A cosign bump is read against this note before it is applied.

## Two build-log warnings come from the vendors

A pre-flight on the 44.20260921 base (measured 2026-09-23) prints two warnings the repository
cannot remove. `Warning: skipped OpenPGP checks for 1 package from repository: @commandline` is
dnf5 installing the GitKraken RPM, which its vendor does not sign; `31-git-tools.sh` checks the
payload digests and passes `--no-gpgchecks` on purpose.
`libsemanage.semanage_rename: WARNING: rename(...) failed: Invalid cross-device link` is the
`%post` of Fedora's `swtpm-selinux` writing the SELinux store on the container's overlay: it
falls back to a copy, and the image carries the package's three modules (`semodule -l`).

The same log carries
`modprobe: FATAL: Module uhid not found in directory /lib/modules/<kernel>`, from the `%post`
of Sunshine loading `uhid` for the kernel the build runs on: the building host's,
`7.0.0-1012-azure` on the runner, never the image's. The image carries `uhid.ko` for its own
kernel and the package's `60-sunshine.conf` loads it at boot, the file `41-sunshine.sh`
requires and `tests/41-sunshine.sh` reads for `uhid`. The `%post` then prints
`rpm-ostree environment detected, skipping post install steps`: it finds `rpm-ostree` in the
base and leaves out its udev reload.

The other `Failed` and `Conflict` lines, the same in the three flavours, are not warnings
either. `Failed to preset unit: Unit ublue-user-setup.service does not exist`, once, is the
`%post` of `ublue-setup-services` running `systemd-update-helper install-system-units` on a
unit the package ships only under `/usr/lib/systemd/user/`; `30-ide.sh` enables it with
`systemctl --global`. `Failed to connect to audit log, ignoring: Invalid argument` and
`plugdev.conf:1: Conflict with earlier configuration for group 'plugdev'`, 13 lines each, come
from the sysusers scriptlets of the packages installed: `systemd-sysusers --dry-run` in the
base image alone prints both, `plugdev.conf` belonging to no package and colliding with
`openrazer.conf:3` of `openrazer`.

## A module built against kernel-devel gets no BTF

kbuild writes a module's BTF with pahole against `vmlinux` in the kernel build tree. The base's
`kernel-devel` ships no `vmlinux` and no pahole, so every module printed
`Skipping BTF generation … due to unavailability of vmlinux`, and on the OGC kernel
`warning: pahole version differs from the one used to build the kernel`
(`CONFIG_PAHOLE_VERSION=131`; Fedora 44 ships dwarves 1.30 and, in testing, 1.32; measured
2026-09-23). `scripts/extract-vmlinux` recovers a `vmlinux` with its `.BTF` section from the
kernel image, and pahole 1.31 built from its tag gives the modules `.BTF` and `.BTF.base`,
which `strip --strip-debug` keeps.

## An arithmetic syntax error escapes `set -e`

Under `set -euo pipefail`, `x=$((5 - $(printf '')))` prints `syntax error: operand expected`
and bash drops the rest of the top-level command it is running: inside a function, the
function's remaining lines and both branches of the caller's `if … else … fi` never ran; inside
a `for` body, the loop stopped at its first pass. The script went on with its next line and
ended with the status of the last command it ran, 0 after an `echo`; only a dropped command
that is the script's last, as `main "$@"` is, ends it with 1 (measured 2026-09-23 with bash
5.3.9). `(( n += $(printf '') ))` is an ordinary failure with status 1, which `set -e` stops
on. Rule 10 of `check-form.sh` refuses a `$( )` inside `$(( ))`.

## A scriptlet rewrote a packaged `.pyc`

The `%post` of `libvirt-daemon-driver-network`, installed by `22-virtualization.sh`, runs
`firewall-cmd --reload --quiet`, a `#!/usr/bin/python3 -sP` script. At start Python imports
`_distutils_hack` through `distutils-precedence.pth`, and the base's `__init__.cpython-314.pyc`
records a source mtime of `0x69af5f00` where the source has 0, so the interpreter compiles it
again and writes it over the packaged file. Measured 2026-09-23 on the 44.20260921 base:
`rpm -V --nomtime python3-setuptools` printed
`S.5...... /usr/lib/python3.14/site-packages/_distutils_hack/__pycache__/__init__.cpython-314.pyc`
in the three pre-flight images and nothing in their three bases; in the base,
`firewall-cmd --reload --quiet` alone (status 36) sufficed for `rpm -V --nomtime` to print the
same line, and with `PYTHONDONTWRITEBYTECODE=1` in front it exited 0. `lib/env.sh` exports the
variable to every build script and `tests/run.sh` to every test. The last gate of the
`Containerfile` requires `rpm -V --nomtime python3-setuptools` clean on the final image, which
holds what the build RUN and the test RUN wrote: without the variable, the `python3` of
`tests/33-mise.sh` makes a rewrite of its own.

## An anonymous probe of a GHCR package never published answers 403

`skopeo list-tags --no-creds docker://ghcr.io/matrixdj96/<package>` lists the tags of the three
published packages, and for a package never published fails with
`Requesting bearer token: received unexpected HTTP status: 403 Forbidden`; logged in, the same
probe fails with `fetching tags list: name unknown` (measured 2026-10-01 with skopeo on this
project's packages and a never-published name). `release-tag.sh` reads `name unknown` as a
package with no tag taken and any other failure as a failed probe, so the release job logs in
to GHCR before it resolves the tag: anonymously, a flavour not yet published would stop the
run.
