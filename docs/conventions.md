# Conventions

Rules for writing build scripts, tests and CI in this repo. `AGENTS.md` carries the short
version; this file carries the reasons and the measured facts behind them.

## Bash

- `#!/usr/bin/env bash`, `set -euo pipefail` (build scripts get it from `lib/env.sh`).
- Clean under `shellcheck -x -P SCRIPTDIR --severity=warning` (`-x -P`: the sourced libraries
  are followed, so a variable a library sets is known) and formatted by
  `shfmt --indent 4 --case-indent --binary-next-line --space-redirects`.
- shfmt is Fedora 44's release, 3.7.0 (MEASURED 2026-09-02 in `quay.io/fedora/fedora:44`). CI
  runs it there; the edit hook (`.claude/hooks/lint-edit.sh`) uses the host binary only when it
  is a 3.7.x and the same container otherwise. The host of record ships 3.13.1, whose defaults
  differ (`> /dev/null` vs `>/dev/null`), so the version must be fixed for the diff to mean
  anything.
- A function that a caller may run under `if`/`||` returns a status; it never calls `exit`
  (under `if`, `exit` kills the script and `2>/dev/null` hides why — `resolve-base.sh` shipped
  that defect for one commit).
- A comment must not start with `# shellcheck` unless it is a directive: shellcheck parses it
  and fails on the "malformed directive".

## Build scripts

- One script per feature, `NN-<feature>.sh`, sourcing `lib/env.sh` first.
- Third-party packages come from a `.repo` vendored under `system_files/etc/yum.repos.d/` with
  every section `enabled=0`, installed with `install_from_repo <section> <pkg>..`; COPR
  packages with `copr_install_isolated <owner/project> <pkg>..`. The gate
  `90-validate-repos.sh` refuses an enabled addition, a vendored file rewritten by a `%post`
  (1Password's does), and any change to a base repository file.
- `dnf5 config-manager setopt <id>.enabled=0` is not used: on repositories added from a file it
  is a silent no-op (v1 gotcha #2, measured 2026-05). Files are edited or replaced instead.
- Nothing is pinned to a release for vendor RPMs and GitHub releases: the build resolves the
  latest. The base image is pinned to the digest CI resolved, and the two kernel modules are
  pinned to a commit (decision 1.5g: reproducibility of the module).
- A vendor's signing key is pinned, on purpose: the armored key ships under
  `system_files/etc/pki/rpm-gpg/RPM-GPG-KEY-<vendor>`, the `.repo` reads it with
  `gpgkey=file://`, and the feature script calls `assert_key_fingerprint` before the install:
  the fingerprint measured on the vendor's published key is pinned once, in the `KEY_FPR` table
  of `lib/gpg.sh` (with the URL each key was read from), which the feature's test reads too. A
  key rotation is then a reviewable diff plus a new table line, never a silent download at
  build time.
- A package that unpacks under `/opt` needs `mkdir -p /var/opt` before its install (`/opt` is a
  symlink to `var/opt`, absent in a build: cpio fails) and nothing else: `80-fix-opt.sh` moves
  every `/var/opt/<name>` to `/usr/lib/opt/<name>` and writes the tmpfiles line that recreates
  the link on the host. Paths baked into the application keep their `/opt/...` form; the smoke
  test checks them with `readlink`, not `-x` (the link dangles in the build).
- An out-of-tree kernel module is a `build_files/kmods/<name>/source.env` (URL, full COMMIT,
  KO_NAME, KO_BUILD_PATH, KO_VERSION) built by the kmod-builder stage against the base's own
  `kernel-devel`; the pin is to a commit on purpose (decision 1.5g), the checkout is proven to
  be that commit, and the staged `.ko` is asserted readable, stamped for the image's kernel
  (vermagic; v1 gotcha #33: a mismatch never loads) and at the expected MODULE_VERSION. The
  modules are unsigned; the recipe that loads them says so when modprobe refuses them.
- A package `%post` runs in the build, not on the host: what it does is read
  (`rpm -qp --scripts`) before the package enters a script, and every effect that belongs to a
  host (a group in `/etc/group`, a unit enabled) is handled explicitly. `groupadd` in a `%post`
  lands in `/etc/group`; `95-clean-stage.sh` relocates it to `/usr/lib/group`, where NSS
  (`altfiles`) reads it; membership for humans is a boot hook's job.
- Writes to files the base image ships end on a fresh inode (`mv`, `install`, `sed -i`,
  `rsync`) where it costs nothing. The runner kernel of `ubuntu-26.04` does not lose in-place
  writeback (`docs/gotchas.md` § Torn writeback: measured clean in 4 of 4 arms, reproduced on
  `ubuntu-24.04`), so no cold sweep and no helper exist; CI is pinned to that runner for it.

## ujust recipes

- A recipe that replaces one of Bazzite's ships in a file with the same name under
  `system_files/usr/share/ublue-os/just/` (decision 1.5f: same name, upstream's recipe
  removed). The base justfile imports the path, so nothing else changes; the base's file must
  hold only the recipes we replace (`84-bazzite-virt.just` and `82-bazzite-sunshine.just`: one
  each, measured 2026-09-02 with `just --summary`), and `70-justfile.sh` refuses the build when
  the base's recipe set (recorded by `00-prep.sh` before the copy) differs from ours. When the
  base file holds other recipes too, the recipe is listed in `OVERRIDES` of `70-justfile.sh`,
  which cuts it out of the base file and proves the rest unchanged.
- Our own recipes live in `95-bazzite-mx.just`, imported last. With `allow-duplicate-recipes`
  and duplicate names across imports the earlier import wins (just manual, "Imports"; measured
  on just 1.57.0, 2026-09-02): a recipe of ours can never shadow a base recipe from there, and
  the build fails on any name defined in two files.
- A recipe that needs more than a few lines of logic calls a helper under
  `system_files/usr/libexec/bazzite-mx-<x>`, the recipe staying a thin front (help, not as
  root, `sudo` where root is needed, the call). The helper takes fixture knobs (`ROOT=`,
  `FIXTURE=`, a `file://` feed) so the smoke test runs the real code positive and known-bad in
  the build, and ships a `--self-test` when it has pure functions worth pinning.
- Recipes are `just --unstable --fmt --check` clean and start with
  `source /usr/lib/ujust/ujust.sh` (colours, `Choose`). A `help` action comes before the "not
  as root" check so the smoke test can run the recipe body in the build.
- What the image already does (a unit enabled, a package installed, a module option) is not
  redone by a recipe: the recipe reports it (`status`) and does only what needs the host (an
  opt-in module, a per-user choice).

## Boot hooks

Scripts under `system_files/usr/share/ublue-os/system-setup.hooks.d/` run as root at every boot
through `ublue-system-setup.service` (`ublue-setup-services`, after `rpm-ostreed`, before user
sessions). The dispatcher runs `bash <script>` and ignores the exit status, so:

- a hook converges on every boot (check, then change only what differs) instead of stamping a
  version with libsetup's `version-script`, which records the run before the body executes and
  never repeats a failed one nor reaches a user created later;
- a hook that cannot do its job prints one `ERROR:` line to stderr and exits 1: the journal
  line is its only signal;
- a hook takes a fixture prefix (`usermod --prefix`, files under a temporary tree) so its smoke
  test exercises the real script, positive and known-bad, without touching the image.

User hooks (`user-setup.hooks.d/`, `ublue-user-setup.service`, every graphical session) follow
the same three rules; their "check" must be cheap enough for every login (read a file, never
spawn the application: the VS Code hook reads `extensions.json`), and their fixture is `HOME`
plus a stub binary first in `PATH`.


## Tests

- `tests/NN-<feature>.sh` with the same stem as the build script; `tests/run.sh` refuses a
  script without a test and a test without a script.
- A test prints `OK: <what>` or `FAIL: <what>` per check and exits 0; the runner fails the
  build on any `FAIL:` line, on a non-zero exit, and on a test that printed no `OK:` line.
- Tests run offline (`--network=none`) on the tree clean-stage left, with tmpfs on `/run` and
  `/tmp`: they see what the image ships, not what the build had.
- A check several tests make (a package with its version, a unit's enablement, a `.desktop`
  file, a recipe file's formatting, a recipe's `help`) is a function of `tests/lib.sh`, sourced
  first; a check made once stays in its test.

## Positive control

A check that has only ever passed proves nothing. Every guard ships a `--self-test` that feeds
it known-bad input and requires the failure, and the self-test runs in CI (`lint` job for the
resolver, the test `RUN` for the validator and the runner). When a new probe is added, it is
seen red on a lesion before its first green counts.

## CI

- Workflow `name:` Title Case; job and step names sentence case, imperative + object; env vars
  `SCREAMING_SNAKE_CASE`; outputs `snake_case`, one key name across workflows.
- Concurrency groups are literal `bazzite-mx-<phase>[-<key>]`; `${{ github.workflow }}` is
  never used in a group (a `workflow_call` callee inherits the caller's name and cancels
  itself, v1 measured 2026-05-14).
- Every `uses:` is pinned to a commit SHA with the version in a trailing comment.
- `ubuntu-26.04` for jobs that need podman, skopeo or Homebrew; `ubuntu-slim` only for `gh`,
  `jq`, `curl` work (it has no container engine, no Homebrew and shellcheck 0.9.0).
- `runner.temp` is not available in a job-level `env:`; steps read `$RUNNER_TEMP`.
- A dispatch of a workflow that exists only on a branch goes by file name:
  `gh workflow run build.yml --ref <branch>`; `-f rechunk=true` runs the main profile there.
- `ubuntu-26.04` is also the only runner whose kernel keeps in-place writeback intact
  (`gotchas.md` § Torn writeback): a runner change is a change to that measurement.
- Two profiles, one reusable workflow: what `main` and a release run differ in from the sandbox
  is an input (`rechunk`, later `publish`), never a second copy of the steps (aurora
  `reusable-build.yml`: `publish` as an input, steps with `if: inputs.publish`).
- Every check CI runs on an image is a script under `.github/scripts/` with a `--self-test` the
  `lint` job runs; the workflow calls the script, it does not restate the checks.
- One labels file per build (`image-labels.sh`), passed to `podman build` and again to
  `build-chunked-oci`: a composed image inherits no config, and a `podman build` without labels
  keeps the base's (`gotchas.md`).
- Values an expression computes reach a step through `env:`, never inline in `run:` (an input
  or a label with a quote would break the script; GitHub docs, "Security hardening for GitHub
  Actions", read 2026-09-02).
- A secret proves itself before it is needed: the main profile signs the chunked image's digest with
  `SIGNING_SECRET` and verifies with `cosign.pub`, so a rotated or mispasted key fails on a
  push to `main`, not in the release run.
- Publishing is an input, never an event: every step that reaches GHCR sits behind
  `if: inputs.publish`, `publish` is passed by `release.yml` alone, and `release.yml` has one
  trigger, `workflow_dispatch`. A job's permissions cannot follow an input, so the callee
  declares the set its publishing steps need and every caller grants it (GitHub docs, reusable
  workflows: a caller may only maintain or reduce them); the token of a sandbox run can write
  packages and no step uses it.
- An image travels between jobs by digest, never by tag: the build job writes
  `release-<flavour>.env` and uploads it as an artifact; the gate inspects
  `docker://<image>@<digest>`. A `:staging` tag left by an earlier run of the same day would
  carry the same version (2.5 #2.7).
- A verifier is shown failing before its first pass: the gate runs `cosign verify` with
  `cosign.pub` and `gh attestation verify --repo MatrixDJ96/bazzite-mx` on the flavour's own
  base (the `base.digest` the build pinned) first, and only a signature-class rejection counts
  (a network error also exits non-zero).
- A release tag is written once: the gate refuses to copy onto a `:<tag>` that already points
  at another digest; `:stable` is the one alias that moves, and only through the gate or
  `promote.yml`. Immutable releases are enabled on the repository for the same reason.
- Binaries the workflows install take their version from an input (`cosign-release`,
  `syft-version`, `ORAS_VERSION`), never "latest"; `refresh-pins.sh` reads those inputs. The
  `ubuntu-26.04` runner ships podman, skopeo, docker, gh, jq and yq, not cosign, syft or oras
  (runner-images `Ubuntu2604-Readme.md`, read 2026-09-02).
- Retries are loops in the step (`podman push` twice, three attempts; `skopeo --retry-times`),
  not an action: one pin fewer for a `for` loop.

## Commits

Conventional Commits; one commit per verified feature (script + test + doc). `develop` first,
`main` with an explicit OK. Never `--force`, `--no-verify`, `--amend` without an explicit ask.
