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

## `ghcr-cleanup-action` matches `packages` by pattern only with `expand-packages`

`use-regex: true` reaches `delete-tags` and `exclude-tags`; `packages` stays a comma-separated
list of literal names unless `expand-packages: true`, which lists the owner's packages through
the Packages API and requires a classic PAT (`src/main.ts:50-90` and `src/config.ts:92-100` at
v1.2.2, read 2026-09-02; `GITHUB_TOKEN` is refused there). With `expand-packages` and
`use-regex`, the whole `packages` string is ONE regular expression, not a list of them.
