# Gotchas

Surprises found on this project that a reader would otherwise rediscover the hard way. Each one
says what happens, how and when it was measured, and what the repository does about it. The
rules themselves live in [`conventions.md`](conventions.md).

Contents, in the order of the entries: torn writeback on 6.17-azure · command | grep -q ·
stub-resolv.conf left in the image · remove-unwanted-software v9 · force-push without a push
run · pre-flight without the changed script · arithmetic error escapes set -e.

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
`--mount=type=bind,from=ctx` is not hashed into it. After a change under `build_files/`, a
pre-flight whose base layers are cached reports `Using cache` on the build step and exits 0 in
about three minutes with an image built from the old scripts. Measured 2026-09-04: the closed
flavour's pre-flight after a new feature printed ten `Using cache` lines, while `--no-cache`
produced the real build. CI is not affected, a fresh runner having no layer cache.

## An arithmetic syntax error escapes `set -e`

Under `set -euo pipefail`, `x=$((5 - $(printf '')))` prints `syntax error: operand expected`
and bash drops the rest of the top-level command it is running: inside a function, the
function's remaining lines and both branches of the caller's `if … else … fi` never ran; inside
a `for` body, the loop stopped at its first pass. The script went on with its next line and
ended with the status of the last command it ran, 0 after an `echo`; only a dropped command
that is the script's last, as `main "$@"` is, ends it with 1 (measured 2026-09-23 with bash
5.3.9). `(( n += $(printf '') ))` is an ordinary failure with status 1, which `set -e` stops
on. Rule 10 of `check-form.sh` refuses a `$( )` inside `$(( ))`.
