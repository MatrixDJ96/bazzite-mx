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
- Writes to files the base image ships end on a fresh inode (`mv`, `install`, `sed -i`,
  `rsync`) where it costs nothing; whether the runner kernel still loses in-place writeback (v1
  gotcha #34) is decided by the experiment recorded in `docs/gotchas.md`.

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
  `gh workflow run build.yml --ref <branch>`.

## Commits

Conventional Commits; one commit per verified feature (script + test + doc). `develop` first,
`main` with an explicit OK. Never `--force`, `--no-verify`, `--amend` without an explicit ask.
