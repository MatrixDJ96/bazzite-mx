# Gotchas

Surprises found on this project that a reader would otherwise rediscover the hard way. Each one
says what happens, how and when it was measured, and what the repository does about it. The
rules themselves live in [`conventions.md`](conventions.md).

Contents, in the order of the entries: torn writeback on 6.17-azure · just duplicate recipe ·
ujust.sh readonly names · kvmfr qemu.conf edit · kvmfr under sudo · grep -v on an empty set ·
command | grep -q · modinfo /lib/modules path · stub-resolv.conf left in the image ·
remove-unwanted-software v9 · force-push without a push run · 1Password BrowserSupport gid ·
pre-flight without the changed script · skel and existing accounts · KXmlGui write-back ·
image-info.json vs OCI label day · FAIL branch before its verdict · sunshine --version home ·
Docker FORWARD policy and libvirt · recipe description line · vendor build-log warnings · no
BTF from kernel-devel · arithmetic error escapes set -e · scriptlet rewrote a .pyc.

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
recipe, so `70-justfile.sh` replaces the base file, and fails the build on any name defined
twice.

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
the list first. Every `| grep -q` of the repo captures first and `check-form.sh` refuses the
shape.

## `modinfo -F filename` and `modprobe --show-depends` print `/lib/modules/...`

The module tools print the legacy path even when the file lives under `/usr/lib/modules`
(`/lib` being a symlink to `usr/lib`), so a literal string comparison against the staged path
fails (measured 2026-09-02). `50-kmods.sh` compares `realpath` of the resolved module against
`realpath` of the file it installed.

## A networked RUN leaves `/run/systemd/resolve/stub-resolv.conf` in the image

buildah gives a RUN the host's resolver by binding a file at
`/run/systemd/resolve/stub-resolv.conf`, the target of the base's `/etc/resolv.conf` symlink.
The directories and the placeholder file then stay in the layer: 3 entries under `/run` after
one networked RUN on the base, none when the RUN mounts a tmpfs on `/run` (measured
2026-09-02). Every `RUN` of the image stage therefore mounts a tmpfs on `/run`; the build and
the tests mount one on `/tmp` too. `bootc container lint` cannot see them from inside a
container, where podman fills `/run` itself.

## `ublue-os/remove-unwanted-software` v9 fails on `ubuntu-26.04`

Its apt step runs `apt-get remove -y powershell --fix-missing` and the 26.04 runner image has
no such package: `E: Unable to locate package powershell`, exit 100, the job dead before the
build (measured 2026-09-02). The `df` the action prints first showed 92 GB free of 145 GB on
that runner, so the image build fits without freeing anything. The action is not used.
image-template pins commit `695eb75b` of the action, the `v10` merge without the apt step,
which has no release tag.

## A force-push of a rewritten history may create no `push` run

Force-pushing a branch onto a head that shares no ancestor with the previous one created no run
of `build.yml`, while the same workflow file dispatched fine on that ref (measured 2026-09-02:
no run listed six minutes after the push; none again on 2026-09-05 at 20:01Z and on 2026-09-06
at 23:35Z). A path filter is a two-dot diff of the pushed head against the previous head, and
GitHub documents the empty case ("Workflow syntax", `on.push.paths`: "If there are no files
changed, the workflow will not run"). The same shape of push did create the `push` runs once on
2026-09-05 and twice on 2026-09-06, so the rule is not one to rely on either way. After such a
push the run list is read before anything is assumed, and what is missing is dispatched by
hand, `gh workflow run build.yml --ref <branch>`.

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

## A local pre-flight can exit 0 without running a changed build script

buildah keys a `RUN` layer on its command string and its parent layer; the content behind a
`--mount=type=bind,from=ctx` is not hashed into it. After a change under `build_files/` or
`system_files/`, a pre-flight whose base layers are cached reports `Using cache` on the
kmod-builder and build steps and exits 0 in about three minutes with an image built from the
old scripts. Measured 2026-09-04: the closed flavour's pre-flight after a new feature printed
ten `Using cache` lines, while `--no-cache` produced the real build. CI is not affected, a
fresh runner having no layer cache.

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

## The base's image-info.json and its OCI label can name different days

`ghcr.io/ublue-os/bazzite@sha256:437920ba…` carries
`org.opencontainers.image.version=44.20260908` and ships an `image-info.json` whose `version`
is `44.20260907`. `resolve-base.sh` reads the label, while `10-image-info.sh` reads the file,
so `base-version` and the `(Bazzite …)` of `version-pretty` follow the file: a `.dev` build
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

## A recipe's description is the LAST comment line above it

`just --list`, which `ujust` runs, shows one description per recipe and takes it from the last
comment line above the recipe, not from the whole comment block. Measured 2026-09-12 with just
1.57.0: a two-line comment lists as `foo # second line of the description`, the first line
lost. So the description comments of `82-bazzite-sunshine.just` (113 columns) and
`95-bazzite-mx.just` (102 columns) stay on one line: wrapping them to the 100 columns of
`docs/conventions.md` § Form would silently cut what a user reads in `ujust`. `.just` files are
outside the shell catalogue `check-form.sh` measures, so nothing enforces the limit there
anyway.

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
