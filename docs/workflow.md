# Workflow

How a change reaches a host: the branches and the profiles they run. The build itself is in
[`architecture.md`](architecture.md).

Contents: branches and profiles · run the lint job locally.

## Branches and profiles

| Where                        | What runs                                                            | What it proves                                                     | What it publishes                                          |
| ---------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------ | ---------------------------------------------------------- |
| `develop`, `main`, pull requests | the `lint` job, then the three flavours                              | the tree builds                                                    | nothing                                                    |

The `lint` job runs shellcheck, `check-form.sh` and `check-commits.sh` (every commit of the
pushed ref, `conventions.md` § Commits) on the runner, then shfmt, yamllint and
`just --fmt --check` on the recipe files inside `quay.io/fedora/fedora:44`, the `just` release
the image ships. It also runs `node --check` on the Plasma update scripts. The `--self-test` of
every script under `.github/scripts/` and of `tests/run.sh` runs right after ShellCheck, before
the checks it proves.

`build.yml` ignores pushes that touch only `**.md`, `docs/`, `.claude/` or `LICENSE`.

## Run the lint job locally

The shell catalogue is every `.sh` git does not ignore, tracked or not, plus the extensionless
libexec helpers, found by their shebang; shfmt, yamllint and `just` run in the container the
job uses, so the releases match the image's. The job's self-tests and `check-commits.sh` are
the lines of `AGENTS.md` § Build & run.

```bash
scripts=$({ git ls-files -co --exclude-standard '*.sh'
  git grep --untracked -l '^#!/usr/bin/env bash'; } | sort -u | tr '\n' ' ')
recipes=$(git ls-files '*.just' | tr '\n' ' ')
shellcheck -x -P SCRIPTDIR --severity=warning $scripts
./.github/scripts/check-form.sh $scripts
for f in $(git ls-files '*.js'); do node --check "$f"; done
podman run --rm -v "$PWD:/repo:ro,z" -w /repo quay.io/fedora/fedora:44 \
  bash -euo pipefail -c "dnf -q install -y shfmt yamllint just >/dev/null
    shfmt -d -i 4 -ci -bn -sr $scripts; yamllint --strict .
    for f in $recipes; do just --unstable --fmt --check --justfile \$f; done"
```
