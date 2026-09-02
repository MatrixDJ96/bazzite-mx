# Workflow

How a change reaches a host: the branches and the profiles they run. The build itself is in
[`architecture.md`](architecture.md).

Contents: branches and profiles · run the lint job locally · what takes the owner's OK.

## Branches and profiles

| Where                        | What runs                                                            | What it proves                                                     | What it publishes                 |
| ---------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------ | --------------------------------- |
| `develop`, `main`, pull requests | the `lint` job, then the three flavours                              | the tree builds                                                    | nothing                           |

The `lint` job runs shellcheck, `check-form.sh` and `check-commits.sh` (every commit of the
pushed ref, `conventions.md` § Commits) on the runner, then shfmt, yamllint and
`just --fmt --check` on the recipe files inside `quay.io/fedora/fedora:44`, the `just` release
the image ships. The `--self-test` of every script under `.github/scripts/` and of
`tests/run.sh` runs right after ShellCheck, before the checks it proves.

`build.yml` ignores pushes that touch only `**.md`, `docs/`, `.claude/` or `LICENSE`.

A force-push that replaces the history may create no `push` run ([`gotchas.md`](gotchas.md) § A
force-push of a rewritten history may create no `push` run). Read the push run of the new head
first, for `build.yml`; `--commit` wants the full sha, and an empty list means the run is
missing:

```bash
gh run list --repo MatrixDJ96/bazzite-mx --workflow <workflow> --event push \
  --commit "$(git rev-parse <branch>)"
```

Dispatch only what is missing: a `build.yml` dispatch cancels a push run of the same ref
(`cancel-in-progress`). For `main`:

```bash
gh workflow run build.yml --repo MatrixDJ96/bazzite-mx --ref main
```

## Run the lint job locally

The shell catalogue is every `.sh` git does not ignore, tracked or not, plus the extensionless
libexec helpers, found by their shebang; shfmt, yamllint and `just` run in the container the
job uses, so the releases match the image's.

```bash
scripts=$({ git ls-files -co --exclude-standard '*.sh'
  git grep --untracked -l '^#!/usr/bin/env bash'; } | sort -u | tr '\n' ' ')
recipes=$(git ls-files '*.just' | tr '\n' ' ')
shellcheck -x -P SCRIPTDIR --severity=warning $scripts
./.github/scripts/check-form.sh $scripts
podman run --rm -v "$PWD:/repo:ro,z" -w /repo quay.io/fedora/fedora:44 \
  bash -euo pipefail -c "dnf -q install -y shfmt yamllint just >/dev/null
    shfmt -d -i 4 -ci -bn -sr $scripts; yamllint --strict .
    for f in $recipes; do just --unstable --fmt --check --justfile \$f; done"
```

## What takes the owner's OK

A push to `main`. Any change to the repository settings, and anything that touches a host.
