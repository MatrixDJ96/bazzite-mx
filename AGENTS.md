# bazzite-mx — a personal bootc image built on Bazzite

Three flavours of one `Containerfile`, `bazzite-mx`, `bazzite-mx-nvidia-open` and
`bazzite-mx-nvidia`, on Bazzite's KDE `stable` bases, differing only in the build arg
`BASE_IMAGE`. The image is the system layer: apps are Flatpak, CLI tools
Fedora RPMs or Homebrew, mutable userspace distrobox. GitHub repo `MatrixDJ96/bazzite-mx`;
CI builds the flavours, a local build is a podman pre-flight.

## Build & run

```bash
for s in ./.github/scripts/*.sh; do "$s" --self-test; done  # each CI script's guard, offline
shellcheck -x -P SCRIPTDIR --severity=warning <file>.sh     # the lint job's ShellCheck
./.github/scripts/check-form.sh <file>.sh                   # banned shapes, 100 columns
./.github/scripts/check-commits.sh HEAD                     # every commit message on the ref
```

- The commands need bash, git, jq and shellcheck on the host, podman and
  skopeo for the pre-flight, podman for the lint job's container (shfmt, yamllint);
  `.claude/hooks/lint-edit.sh` skips any linter it cannot find.
- The `lint` job of `build.yml` runs the first four, and shfmt and yamllint in
  `quay.io/fedora/fedora:44`; the local equivalent is `docs/workflow.md` § Run the lint job
  locally.

## Layout

- `.github/scripts/` — one owner per CI artefact, each with a `--self-test`.

## Conventions

- A shell script opens with `#!/usr/bin/env bash` and `set -euo pipefail`, passes ShellCheck
  and Fedora 44's `shfmt --indent 4 --case-indent --binary-next-line --space-redirects`, and
  has the form of `docs/conventions.md` § Form. The lint job fails it on ShellCheck, shfmt
  and the shapes and width `check-form.sh` reads; review reads the rest.
- A script that guards something ships a `--self-test` that feeds it known-bad input and
  requires the failure; what an assertion counts comes from an independent record, never from
  the thing under test (`docs/conventions.md` § Positive control).
- A pin enters only against an observed problem, cited. The base digest is pinned on purpose.
- A commit message is `<type>(<scope>): <what>` within 72 columns with no trailing period and
  no trailer, or `check-commits.sh` fails the lint job; a body is optional, after a blank line,
  in natural lines, one per point, never hard-wrapped.
- An entry of `docs/divergences.md` cites its source (upstream file, manual page, URL).
- A workflow's concurrency group is the literal `bazzite-mx-<phase>[-<key>]`: a `workflow_call`
  callee inherits the caller's `${{ github.workflow }}` and waits on its own caller. Names,
  runners and action pins: `docs/conventions.md` § CI.

## Gotchas

- A file rewritten by a shell command gets no lint: `.claude/hooks/lint-edit.sh` fires on the
  Edit and Write tools only, so run shellcheck, `check-form.sh` and shfmt on it by hand.
- A push touching only `**.md`, `docs/`, `.claude/` or `LICENSE` runs no `build.yml`.
- A force-push of a rewritten history may create no `push` run: list the runs of the new head
  and dispatch only what is missing (`docs/workflow.md` § Branches and profiles).

## Boundaries

- A push goes to `develop` first, whose sandbox builds the three flavours and publishes
  nothing; a push to `main` and a repository setting take the owner's OK
  (`docs/workflow.md` § What takes the owner's OK).

## Docs

- `docs/conventions.md` — before writing a script or workflow.
- `docs/divergences.md` — what the image changes over Bazzite and why, one entry per feature.
- `docs/workflow.md` — branches, the local lint run, what takes the owner's OK.
