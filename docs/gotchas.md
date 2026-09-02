# Gotchas

Surprises found on this project that a reader would otherwise rediscover the hard way. Each one
says what happens, how and when it was measured, and what the repository does about it. The
rules themselves live in [`conventions.md`](conventions.md).

Contents, in the order of the entries: torn writeback on 6.17-azure · ujust.sh readonly names ·
kvmfr qemu.conf edit · kvmfr under sudo · grep -v on an empty set · command | grep -q ·
stub-resolv.conf left in the image · remove-unwanted-software v9 · force-push without a push
run · pre-flight without the changed script · image-info.json vs OCI label day · Docker FORWARD
policy and libvirt · arithmetic error escapes set -e · scriptlet rewrote a .pyc.

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
helper's `status | grep -q` turned a passing check red during a pre-flight. Capture the output
in a variable, then grep the variable. The shape can pass for months and fail on a base change:
`tests/95-clean-stage.sh` read the kernel lock through `dnf5 versionlock list | grep -q` and
was green while the list held five entries; the base of 2026-09-07 (`44.20260907`, kernel
7.2.3-ogc3.1) locks every qt6 and plasma package too, the list runs to 3179 lines, and the
three flavours went red on `tests: FAILED` with a docs-only change (measured 2026-09-07, status
141 reproduced in the base). The test captures the list first. Every `| grep -q` of the repo
captures first and `check-form.sh` refuses the shape.

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

## A local pre-flight can exit 0 without running a changed build script

buildah keys a `RUN` layer on its command string and its parent layer; the content behind a
`--mount=type=bind,from=ctx` is not hashed into it. After a change under `build_files/` or
`system_files/`, a pre-flight whose base layers are cached reports `Using cache` on the
build step and exits 0 in about three minutes with an image built from the old scripts.
Measured 2026-09-04: the closed flavour's pre-flight after a new feature printed ten
`Using cache` lines, while `--no-cache` produced the real build. CI is not affected, a fresh
runner having no layer cache.

## The base's image-info.json and its OCI label can name different days

`ghcr.io/ublue-os/bazzite@sha256:437920ba…` carries
`org.opencontainers.image.version=44.20260908` and ships an `image-info.json` whose `version`
is `44.20260907`. `resolve-base.sh` reads the label, while `10-image-info.sh` reads the file,
so `base-version` and the `(Bazzite …)` of `version-pretty` follow the file: a `.dev` build
without `VERSION` would be `44.20260907.dev`. Measured 2026-09-12 on the pre-flight image. Both
numbers are the base's own; the image reports each from its source and neither is rewritten.

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
holds what the build RUN and the test RUN wrote.
