# Workflow

How a change reaches a host: the branches, the release run, the retention and the pin refresh.
The build itself is in [`architecture.md`](architecture.md).

Contents: branches and profiles · run the lint job locally · probe a pre-flight image by hand ·
the release run · promotion and the recovery signer ·
the weekly trigger and the upstream watcher · GHCR retention · keeping the pins fresh.

## Branches and profiles

| Where                        | What runs                                                            | What it proves                                                     | What it publishes                                          |
| ---------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------ | ---------------------------------------------------------- |
| `develop`, pull requests     | the `lint` job, then the three flavours with `check-image.sh`        | the tree builds and the artefact carries what it claims            | nothing                                                    |
| `main`                       | the same plus the chunked image, its probe and the signing-key proof | the image a host would pull, and the key a release would sign with | nothing                                                    |
| `release.yml`, dispatch only | the release profile, the gate, the GitHub Release                    | see below                                                          | `:staging`, `:<tag>`, `:stable` when promoted, the Release |

The `lint` job runs shellcheck, `check-form.sh` and `check-commits.sh` (every commit of the
pushed ref, `conventions.md` § Commits) on the runner, then shfmt, yamllint and
`just --fmt --check` on the recipe files inside `quay.io/fedora/fedora:44`, the `just` release
the image ships. It also runs `node --check` on the Plasma update scripts. The `--self-test` of
every script under `.github/scripts/` and of `tests/run.sh` runs right after ShellCheck, before
the checks it proves.

A push never releases: `release.yml` has one trigger, `workflow_dispatch`. The main profile is
proven on a branch before it reaches `main`, naming the branch you want it to run on:

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

## The release run

```
release.yml   workflow_dispatch: reason (becomes the run name), promote_stable (default false),
              release_tag (default empty)
  version     skopeo login, resolve-base.sh bazzite -> release-tag.sh
              -> release_tag <fedora>.<yyyymmdd>, with .N one past the day's highest suffix
              when a GHCR package of the repository or a GitHub Release already carries
              that day's name or one of its suffixes; a probe that fails stops
              the job, a registry and a release list with no tag at all leave the day's name
              free; a release_tag input is used as given once it has the shape
              <fedora>.<yyyymmdd>[.N], its Fedora is the base's and the same probes show it
              free (release-tag.sh --tag)
              -> resolve-base.sh --digests: the three bases read once, base_digest_<flavour>
  build       reusable-build.yml with release_tag, rechunk and publish; one job per flavour:
                build -> check-image.sh -> compose the chunked image -> check-image.sh again
                -> prove the signing key
                -> SBOM (syft) -> push :staging -> digest from --digestfile -> cosign sign by
                digest -> SBOM attached as a referrer with oras and signed
                -> actions/attest (the GitHub store, not the registry)
                -> release-<flavour>.env uploaded as an artifact
  gate        gate-release.sh release on the three env files, image by digest:
                labels (title, vendor, version = release_tag, revision = the run's commit)
                -> the base the version job resolved, the one the build wrote in its env file
                and the manifest's base.digest label must be one digest (--base <flavour>=)
                -> negative controls on the flavour's own base (cosign.pub must refuse it,
                gh attestation verify must find nothing of ours) -> cosign verify and
                gh attestation verify --repo MatrixDJ96/bazzite-mx -> skopeo copy
                --preserve-digests onto :<tag>, refused when :<tag> already points elsewhere
                -> :stable, once all three passed, only with promote_stable AND vars.PROMOTE_STABLE
  release     changelog.sh (base version from the bases' labels, linked to its Bazzite release;
              the sections of Bazzite's changelog.py: major packages from the SBOMs, commits
              since the previous release's revision, then All Images and Nvidia Images, one
              package per new version; images, kernels and switch commands)
              -> gh release create --latest
```

Dispatch:

```bash
gh workflow run release.yml --repo MatrixDJ96/bazzite-mx --ref main -f reason=manual
gh run list --repo MatrixDJ96/bazzite-mx --workflow release.yml --limit 3
```

The tag is the day's in UTC: `release-tag.sh` reads `date -u`, so the name rolls over at
00:00Z, not at local midnight. A dispatch can force another name; the version job still refuses
a name a package or a release carries:

```bash
gh workflow run release.yml --repo MatrixDJ96/bazzite-mx --ref main -f reason=manual \
  -f release_tag='44.YYYYMMDD.N'
```

With `promote_stable` off, or the repository variable `PROMOTE_STABLE` not `true`, the job
prints that promotion was not requested, the gate leaves `:stable` untouched and the run is
green with the dated tag alone.

## Promotion and the recovery signer

Two dispatch-only workflows act on images already on GHCR:

| Workflow         | Input         | What it does                                                                                       |
| ---------------- | ------------- | -------------------------------------------------------------------------------------------------- |
| `promote.yml`    | `release_tag` | `gate-release.sh promote`: verifies every image `:<tag>` points at, then moves `:stable` onto them |
| `sign-image.yml` | `image`       | signs one image of this repository by digest, then runs `cosign verify` on it                      |

`promote.yml` shares the release run's group, `bazzite-mx-release`, so it never runs beside a
release, and reads no repository variable: the dispatch is the owner's OK.

```bash
gh workflow run promote.yml --repo MatrixDJ96/bazzite-mx --ref main -f release_tag='44.YYYYMMDD'
gh workflow run sign-image.yml --repo MatrixDJ96/bazzite-mx --ref main \
  -f image='ghcr.io/matrixdj96/<image>:<tag>'
```

## The weekly trigger and the upstream watcher

Both live on `main`, because a `schedule` runs on the default branch only, and both dispatch
`release.yml` with a `reason` and `promote_stable=true`. Neither dispatches while
`PROMOTE_STABLE` is not `true`.

| Workflow              | When                                                            | What it does                                                             |
| --------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------ |
| `trigger-release.yml` | `20 3 * * 0` (Sunday 03:20 UTC), or a dispatch                  | dispatches `release.yml` with `reason=weekly`, held as below             |
| `watch-upstream.yml`  | `37 */6 * * *` (every 6 h at :37), or a dispatch with `dry_run` | compares the base digests with our `:stable`, then dispatches on `stale` |

`trigger-release.yml` carries `if: vars.PROMOTE_STABLE == 'true'` on its job, so a skipped run
shows why. `watch-upstream.sh weekly` then holds the dispatch while a release run is queued or
running, or a release already carries the day's UTC date (`<fedora>.<yyyymmdd>[.N]`). The date
is the release's tag, so a watcher release cut before 00:00Z does not hold a weekly after it. A
release list or a run list it cannot read, or a release list that is blank or no JSON list,
makes the run red, with no dispatch.

`watch-upstream.sh decide` dispatches only when all four conditions hold:

- the verdict is `stale`;
- `PROMOTE_STABLE` is `true`;
- no release run is queued or running;
- no release with the same reason started in the last 24 hours.

The reason it passes is `upstream:<12 hex per base>`.

The watcher fails closed. A base that cannot be resolved, an image that cannot be inspected or
a `:stable` without the label make the run red and dispatch nothing; the next cron retries. A
`:stable` that does not exist is `absent`: there is nothing to compare. To read the verdict
without dispatching:

```bash
gh workflow run watch-upstream.yml --repo MatrixDJ96/bazzite-mx --ref main -f dry_run=true
```

## GHCR retention

`clean.yml` runs on `15 0 * * 0` (Sunday 00:15 UTC) and names the three packages in full. It
prunes the versions older than 90 days beyond the 7 newest tagged and the 7 newest untagged,
and excludes `:stable` and `:staging` whatever their age. The `.sig` images and the SBOM
referrer of an image that is gone go with it; the attestations live in GitHub's store and stay.
The dated release tags are prunable; their GitHub Release stays. A dispatch defaults to a dry
run:

```bash
gh workflow run clean.yml --repo MatrixDJ96/bazzite-mx --ref main -f dry_run=true   # read the log
gh workflow run clean.yml --repo MatrixDJ96/bazzite-mx --ref main -f dry_run=false
```

## Keeping the pins fresh

The pins and the binary versions of [`conventions.md`](conventions.md) § CI have no bot; the
repo's own reusable workflow is called by path, which GitHub cannot pin. `refresh-pins.sh`
refreshes them by hand:

```bash
./.github/scripts/refresh-pins.sh --self-test   # the verdicts on fixtures, offline
./.github/scripts/refresh-pins.sh --check       # one row per item, a stale pin is a row
./.github/scripts/refresh-pins.sh --apply       # rewrite the STALE actions and binaries
```

Every lookup goes through `gh api`, which wants a login (`gh auth login` or `GH_TOKEN`) even
for public data: without one every row reads `UNKNOWN`.

| Class      | Item                                                             | Verdicts                    |
| ---------- | ---------------------------------------------------------------- | --------------------------- |
| `action`   | each `uses: owner/repo[/path]@<sha> # <version>`                 | `OK`, `STALE`, `UNKNOWN`    |
| `binary`   | `cosign-release`, `syft-version`, `ORAS_VERSION`                 | `OK`, `STALE`, `UNKNOWN`    |
| `runner`   | each `runs-on:` label against the `actions/runner-images` README | `OK`, `STALE`, `UNKNOWN`    |
| `workflow` | the state of every workflow of the repository                    | `OK`, `DISABLED`, `UNKNOWN` |
| `issue`    | every `owner/repo#N` cited in a workflow comment                 | `OK`, `CLOSED`, `UNKNOWN`   |

`UNKNOWN` means the answer the row needed was not readable (no release for an `action` or a
`binary`, no runner README, no workflow list, no issue) and is never taken for `OK`. `--apply`
rewrites the `action` and `binary` classes only: a runner label, a disabled workflow and a
closed issue each need a human call. After an apply, lint, push to `develop`, and dispatch the
main profile when `reusable-build.yml` changed. Run `--check` whenever you touch `.github/`, and
after a Fedora or Bazzite release. When the base moves to a new Fedora, `--check` reads none of
what moves with it: the `fedora:44` of the lint (`build.yml`, `lint-edit.sh`, `.yamllint.yml`)
and of the docs that name it, the `CI_SHFMT_MINOR` of `lint-edit.sh`, the `44.` of the tag
examples, and the `$releasever` repositories under `system_files/etc/yum.repos.d/`, Docker
first, whose `repomd.xml` for the new release has to answer before the base moves.

The `cosign-release` row is the one a bump is read before applying: v3.1.3 already deprecates
`--new-bundle-format`, and the signatures a host verifies are the layout that flag turned off
([`gotchas.md`](gotchas.md) § cosign 3.1.3 deprecates the flag the signature layout needs). The
row goes `OK` to `STALE` on the version that removes it like any other.
