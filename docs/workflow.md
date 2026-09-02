# Workflow

How a change reaches a host: the branches and the profiles they run. The build itself is in
[`architecture.md`](architecture.md).

Contents: branches and profiles · run the lint job locally · probe a pre-flight image by hand.

## Branches and profiles

| Where                        | What runs                                                            | What it proves                                                     | What it publishes                                          |
| ---------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------ | ---------------------------------------------------------- |
| `develop`, pull requests     | the `lint` job, then the three flavours with `check-image.sh`        | the tree builds and the artefact carries what it claims            | nothing                                                    |
| `main`                       | the same plus the chunked image, its probe and the signing-key proof | the image a host would pull, and the key a release would sign with | nothing                                                    |

The `lint` job runs shellcheck, `check-form.sh` and `check-commits.sh` (every commit of the
pushed ref, `conventions.md` § Commits) on the runner, then shfmt, yamllint and
`just --fmt --check` on the recipe files inside `quay.io/fedora/fedora:44`, the `just` release
the image ships. It also runs `node --check` on the Plasma update scripts. The `--self-test` of
every script under `.github/scripts/` and of `tests/run.sh` runs right after ShellCheck, before
the checks it proves.

The main profile is proven on a branch before it reaches `main`, naming the branch you want it
to run on:

```bash
gh workflow run build.yml --repo MatrixDJ96/bazzite-mx --ref develop -f rechunk=true
```

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

## Probe a pre-flight image by hand

The `/preflight` command names its files after the flavour's image:
`/var/tmp/<image>-base.env`, `-labels.txt`, `-preflight.log` and `localhost/<image>:preflight`,
`<image>` being `bazzite-mx`, `bazzite-mx-nvidia-open` or `bazzite-mx-nvidia`, so the flavours
coexist. The probe and one smoke test by hand, on the labels it stamped:

```bash
# probe a built image: labels, /run and /tmp, lint, packages, modules, the ntfsplus opt-in,
# image-info.json
./.github/scripts/check-image.sh localhost/bazzite-mx:preflight /var/tmp/bazzite-mx-labels.txt
# one smoke test in the built image the way the build runs it, the tree mounted at /ctx; add
# -v <changed copy>:/usr/libexec/bazzite-mx-<name>:ro,z to lesion a helper (mode 755)
podman run --rm --network=none -v "$PWD:/ctx:ro,z" --tmpfs /run --tmpfs /tmp --tmpfs /var/log \
  --tmpfs /var/cache -e BUILD_STATE=/usr/lib/bazzite-mx/build-state \
  localhost/bazzite-mx:preflight bash /ctx/build_files/tests/helpers/verify-host.sh
```
