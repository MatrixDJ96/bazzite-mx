# Workflow

How a change reaches a host: the branches, the release run, the promotions, the recovery tools,
the repository settings the pipeline relies on, and the pin refresh. The build itself is in
[`architecture.md`](architecture.md).

## Branches and profiles

| Where | What runs | What it proves | What it publishes |
|---|---|---|---|
| `develop`, pull requests | the `lint` job, then the three flavours with `check-image.sh` | the tree builds and the artefact carries what it claims | nothing |
| `main` | the same plus the chunked image, its probe and a test signature | the image a host would pull, and the key a release would sign with | nothing |
| `release.yml`, dispatch only | the release profile, the gate, the GitHub Release | see below | `:staging`, `:<tag>`, the Release |

The `lint` job runs shellcheck on the runner, then shfmt and yamllint inside
`quay.io/fedora/fedora:44`. It also runs `node --check` on the Plasma update scripts,
`just --fmt --check` on the recipe files and `check-site.sh` on `site/`. It closes with the
`--self-test` of every script under `.github/scripts/` and of `tests/run.sh`.

A push never releases: `release.yml` has one trigger, `workflow_dispatch`. The main profile is
proven on a branch before it reaches `main`, naming the branch you want it to run on:

```bash
gh workflow run build.yml --repo MatrixDJ96/bazzite-mx --ref develop -f rechunk=true
```

`build.yml` ignores pushes that touch only `**.md`, `docs/`, `site/`, `.claude/` or `LICENSE`.

A force-push that replaces the history leaves no common ancestor and creates no `push` run
([`gotchas.md`](gotchas.md)). Right after one, dispatch the main profile and the page by hand:

```bash
gh workflow run build.yml --repo MatrixDJ96/bazzite-mx --ref main -f rechunk=true
gh workflow run deploy-pages.yml --repo MatrixDJ96/bazzite-mx --ref main
```

## The release run

```
release.yml   workflow_dispatch: reason (becomes the run name), promote_stable (default false)
  version     skopeo login, resolve-base.sh bazzite -> release-tag.sh
              -> release_tag <fedora>.<yyyymmdd>, with .N only when that tag is already on a
              GHCR package of the repository or on a GitHub Release; a probe that answers
              nothing fails the job rather than hand out a tag in use
              -> resolve-base.sh --digests: the three bases read once, base_digest_<flavour>
  build       reusable-build.yml with release_tag, rechunk and publish; one job per flavour:
                build -> compose the chunked image -> check-image.sh -> prove the signing key
                -> SBOM (syft) -> push :staging -> digest from --digestfile -> cosign sign by
                digest and verify -> SBOM attached as a referrer with oras and signed
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
  release     changelog.sh (base version and kernel from the base's labels, package diff from
              the two SBOMs, commits since the previous release's revision, switch commands)
              -> gh release create --latest
```

Dispatch, after the owner's OK:

```bash
gh workflow run release.yml --repo MatrixDJ96/bazzite-mx --ref main -f reason=manual
gh run list --repo MatrixDJ96/bazzite-mx --workflow release.yml --limit 3
```

Until the cutover the gate prints `promotion of :stable not requested` and the run is green
with the dated tag alone: the pilot host rebases on `:<tag>` ([`migration.md`](migration.md)).
The weekly trigger and the upstream watcher dispatch with `promote_stable=true`; the repository
variable `PROMOTE_STABLE` is the switch that lets them move `:stable` (below).

The `:staging` tag is re-pointed by every run and is never deleted by version id: on GHCR a
version is the manifest, and the dated tag and `:staging` share it (measured 2026-09-02 on the
v1 package: five tags on one version).

## The cutover and later promotions

```bash
# 1. the pilot host has run 24 h on :<tag> and ujust verify-host passes but for the tag
gh workflow run promote.yml --repo MatrixDJ96/bazzite-mx --ref main -f release_tag=44.<yyyymmdd>
# 2. from now on the trigger and the watcher may move :stable
gh variable set PROMOTE_STABLE --repo MatrixDJ96/bazzite-mx --body true
```

`promote.yml` re-verifies both images at `:<tag>` (labels, negative controls, signature,
attestation) and copies their digests onto `:stable`. It shares the `bazzite-mx-release`
concurrency group: it never runs beside a release.

## Recovery: a published image without a signature

A run that died between the push and the signature leaves `:staging` unsigned; `sign-image.yml`
signs an image of this repository by digest and verifies it:

```bash
gh workflow run sign-image.yml --repo MatrixDJ96/bazzite-mx --ref main \
  -f image=ghcr.io/matrixdj96/bazzite-mx:staging
```

It refuses any reference outside `ghcr.io/matrixdj96/bazzite-mx` and
`ghcr.io/matrixdj96/bazzite-mx-nvidia-open`.

## Repository settings the pipeline relies on

Checked and set with `gh`, each command run with the owner's OK. State MEASURED 2026-09-04
02:16Z.

| Setting | Why | Check | Set |
|---|---|---|---|
| secret `SIGNING_SECRET` | the cosign private key paired with `cosign.pub`; proven on every push to `main` | `gh secret list --repo MatrixDJ96/bazzite-mx` → present | rotate with `gh secret set SIGNING_SECRET < key`, then a push to `main` proves the pair |
| variable `PROMOTE_STABLE` | the cutover switch: without it no run moves `:stable` | `gh variable list --repo MatrixDJ96/bazzite-mx` → ABSENT (reads as "not true") | `gh variable set PROMOTE_STABLE --repo MatrixDJ96/bazzite-mx --body false` now, `--body true` after the cutover |
| immutable releases | a release tag never moves and a release is never deleted (docs "Immutable releases": tag locked to its commit, assets frozen, an attestation of the release generated) | `gh api repos/MatrixDJ96/bazzite-mx/immutable-releases` → `enabled: false` | `gh api -X PUT repos/MatrixDJ96/bazzite-mx/immutable-releases` (admin) before the first v2 release |
| default workflow permissions | the token starts read-only; each job declares what it needs | `gh api repos/MatrixDJ96/bazzite-mx/actions/permissions/workflow` → `read` | leave |
| workflow states | GitHub disables the cron of a public repository after 60 days without a commit; scheduled runs do not count | `refresh-pins.sh --check`, class `workflow` | `gh api -X PUT repos/MatrixDJ96/bazzite-mx/actions/workflows/<id>/enable` |
| Pages source | the landing page (decision 1.5e), arrives with `deploy-pages.yml` | `gh api repos/MatrixDJ96/bazzite-mx/pages` | with that commit |

## Keeping the pins fresh

Every `uses:` is pinned to a commit SHA with the version in a trailing comment, and the
binaries the workflows install take their version from an input (`cosign-release`,
`syft-version`, `ORAS_VERSION`). No bot refreshes them (decision 1.6);
`.github/scripts/refresh-pins.sh` does, by hand:

```bash
./.github/scripts/refresh-pins.sh --self-test   # the verdicts on fixtures, offline
./.github/scripts/refresh-pins.sh --check       # one row per item, exit 0 always
./.github/scripts/refresh-pins.sh --apply       # rewrite the STALE actions and binaries
```

| Class | Item | Verdicts |
|---|---|---|
| `action` | each `uses: owner/repo[/path]@<sha> # <version>` | `OK`, `STALE` (a newer release, or a comment that disagrees with the sha), `UNKNOWN` (no release readable: never taken for OK), `FOREIGN` (the sha is not a commit of that repository) |
| `binary` | `cosign-release`, `syft-version`, `ORAS_VERSION` (the env of the `install-oras.sh` steps) | `OK`, `STALE`, `UNKNOWN` (compared without the `v`) |
| `runner` | each `runs-on:` label against the table of `actions/runner-images` | `OK` (listed; "still marked preview" when the badge is there), `STALE` (missing or deprecated), `UNKNOWN` |
| `workflow` | the state of every workflow of the repository | `OK`, `DISABLED` (with the re-enable command) |
| `issue` | every `owner/repo#N` cited in a workflow comment | `OK` (open), `CLOSED` (the flag chosen because of it is up for review), `UNKNOWN` |

`--apply` rewrites the `action` and `binary` classes only; a runner label, a disabled workflow
and a closed issue are decisions. After an apply: lint, push to `develop`, and a main-profile
dispatch when the change touches `reusable-build.yml`. Run `--check` at the start of every
round that touches `.github/` and after a Fedora or Bazzite release.

## What takes the owner's OK

A push to `main`, a dispatch of `release.yml` or `promote.yml`, a delete on GHCR, any change to
the repository settings above, and anything that touches a host.
