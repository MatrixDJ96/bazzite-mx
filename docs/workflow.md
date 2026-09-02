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

With `promote_stable` off, or the repository variable `PROMOTE_STABLE` not `true`, the gate
prints `promotion not requested` and the run is green with the dated tag alone. The weekly
trigger and the upstream watcher dispatch with `promote_stable=true`, and only while the
variable is `true` (below): with the switch off the only release runs are the ones you dispatch.

## The weekly trigger and the upstream watcher

Both live on `main` (a `schedule` runs on the default branch only) and both dispatch
`release.yml` with `reason` and `promote_stable=true`; neither dispatches while
`PROMOTE_STABLE` is not `true`.

| Workflow | When | What it does |
|---|---|---|
| `trigger-release.yml` | Tuesday 03:20 UTC, or a dispatch | one job on `ubuntu-slim`: `gh workflow run release.yml --ref main -f reason=weekly -f promote_stable=true`; skipped, visibly, while the variable is not `true` |
| `watch-upstream.yml` | every 6 h at :37, or a dispatch (`dry_run`) | `watch-upstream.sh check`: the digest of `ghcr.io/ublue-os/<base>:stable` against the `base.digest` label of our `:stable`, per flavour; `decide`: dispatch only on `stale`, with the variable `true`, no release run queued or running, and no release with the same reason completed in the last 24 h; then the dispatch, `reason=upstream:<12 hex per base>` |

The watcher fails closed: a base that cannot be resolved, an image that cannot be inspected or
a `:stable` without the label make the run red and dispatch nothing (`UNKNOWN`); the next cron
retries. A `:stable` that does not exist is `absent`: nothing to compare. The verdict on the
day of the commit: `current` on both flavours (MEASURED 2026-09-02 15:31Z: v1's `:stable`
carries the label with the digest of the current base). To read the watcher without
dispatching:

```bash
gh workflow run watch-upstream.yml --repo MatrixDJ96/bazzite-mx --ref main -f dry_run=true
```

## GHCR retention

`clean.yml` runs on `15 0 * * 0` (Sunday 00:15 UTC) and names the three packages in full. It
prunes the versions older than 90 days beyond the 7 newest tagged and the 7 newest untagged,
and excludes `:stable` and `:staging` whatever their age. Signature, SBOM and attestation
referrers whose image is gone go with them. The dated release tags are prunable; their GitHub
Release stays. A dispatch defaults to a dry run:

```bash
gh workflow run clean.yml --repo MatrixDJ96/bazzite-mx --ref main -f dry_run=true   # read the log
gh workflow run clean.yml --repo MatrixDJ96/bazzite-mx --ref main -f dry_run=false  # owner's OK
```

On GHCR a version is the manifest, and several tags share one: `:staging`, re-pointed by every
release run, rides the same version as that run's dated tag. Removing one tag by hand therefore
takes three steps, since deleting a version takes every tag on it.

```bash
gh auth token | skopeo login ghcr.io --username 'MatrixDJ96' --password-stdin
# 1. move each dated tag off the version :stable or :staging points at
skopeo copy --all --preserve-digests 'docker://PACKAGE@OTHER_DIGEST' 'docker://PACKAGE:TAG'
# 2. delete the version that now carries only the tags you want gone, and its .sig referrer
gh api -X DELETE 'user/packages/container/PACKAGE/versions/ID'
# 3. check from outside, then log out
skopeo list-tags 'docker://PACKAGE' && gh release list --repo MatrixDJ96/bazzite-mx
skopeo logout ghcr.io
```

`PACKAGE` is one of the three GHCR packages, `TAG` a dated release tag, `OTHER_DIGEST` the
manifest you move it onto and `ID` the version id from
`gh api user/packages/container/PACKAGE/versions`. Pair the signature referrer with its image
by digest (`skopeo inspect --format '{{.Digest}}'`), never by timestamp.

## The site

`site/` holds seven hand-written pages and one stylesheet, no script and no external asset.
`deploy-pages.yml` publishes the directory on a push to `main` that touches `site/`,
`.github/scripts/check-site.sh` or the workflow itself, and on a dispatch. `build.yml` ignores
`site/`, so a site-only push runs the deployment alone. `check-site.sh` walks every page before
the upload and on every sandbox run.

```bash
./.github/scripts/check-site.sh site             # what CI runs, links fetched
./.github/scripts/check-site.sh site --offline
python3 -m http.server 8765 --bind 127.0.0.1 --directory site   # look at it on port 8765
```

The workflow runs on `main` only: a Pages deployment from another ref would replace the
published site.

## Promotions

```bash
# move :stable onto a release a host has run and verified (ujust verify-host)
gh workflow run promote.yml --repo MatrixDJ96/bazzite-mx --ref main -f release_tag='44.YYYYMMDD'
```

`promote.yml` re-verifies the three images at `:<tag>` through `gate-release.sh promote`
(labels, negative controls, signature, attestation) and copies their digests onto `:stable`. It
shares the `bazzite-mx-release` concurrency group, so it never runs beside a release. Unlike
the two crons and the `promote_stable` input of a release run, it reads no repository variable:
a dispatch moves `:stable` whatever `PROMOTE_STABLE` says, which is why it takes the owner's
OK.

## Recovery: a published image without a signature

A run that died between the push and the signature leaves `:staging` unsigned. `sign-image.yml`
signs an image of this repository by digest and verifies it:

```bash
gh workflow run sign-image.yml --repo MatrixDJ96/bazzite-mx --ref main \
  -f image=ghcr.io/matrixdj96/bazzite-mx:staging
```

It refuses any reference outside the three packages, and it resolves the tag to a digest before
signing, because a tag can move between the two steps.

## Repository settings the pipeline relies on

Checked and set with `gh`, each command run with the owner's OK.

| Setting | Why | Check | Set |
|---|---|---|---|
| secret `SIGNING_SECRET` | the cosign private key paired with `cosign.pub` | `gh secret list` | `gh secret set SIGNING_SECRET < key` |
| variable `PROMOTE_STABLE` | the switch of the automatic releases | `gh variable list` | `gh variable set PROMOTE_STABLE --body false` |
| variable `BUILD_RUNNER` | the label of a self-hosted runner for the build jobs; unset, they run on `ubuntu-26.04` | `gh variable list` | `gh variable set BUILD_RUNNER --body <label>` |
| fork pull request approval | `build.yml` runs on pull requests: with `BUILD_RUNNER` set, a fork's code must not reach the host unapproved | `gh api repos/MatrixDJ96/bazzite-mx/actions/permissions/fork-pr-contributor-approval` | the Actions settings page, "Require approval for all external contributors" |
| immutable releases | a release tag never moves, a release is never deleted, and a deleted release keeps its tag name burnt ([`gotchas.md`](gotchas.md)) | `gh api repos/MatrixDJ96/bazzite-mx/immutable-releases` | `gh api -X PUT repos/MatrixDJ96/bazzite-mx/immutable-releases` |
| default workflow permissions | the token starts read-only, each job declares what it needs | `gh api repos/MatrixDJ96/bazzite-mx/actions/permissions/workflow` | leave |
| workflow states | GitHub disables a public repository's cron after 60 days without a commit | `refresh-pins.sh --check`, class `workflow` | `gh api -X PUT .../actions/workflows/<id>/enable` |
| package visibility | an anonymous host cannot pull a private image | `gh api /user/packages/container/<package> --jq .visibility` | the package's settings page: the REST API has no endpoint |
| Pages source | the Pages actions need the source "GitHub Actions" | `gh api repos/MatrixDJ96/bazzite-mx/pages --jq .build_type` | the repository's Pages settings |

Every `gh` line above wants `--repo MatrixDJ96/bazzite-mx` outside the checkout. GHCR creates a
package private at its first push, so the visibility row applies once per package.

## A self-hosted runner for the build jobs

The three build jobs of `reusable-build.yml` run on the runner the repository variable
`BUILD_RUNNER` names, on `ubuntu-26.04` when it is unset; every other job stays on GitHub. The
variable is the whole switch: `gh variable set BUILD_RUNNER --body <label>` moves the builds,
`gh variable delete BUILD_RUNNER` moves them back, no commit either way. A runner that is
offline while the variable names it holds the jobs in the queue for 24 hours, then GitHub
fails them. A release run builds here too: the cosign key and the `packages: write` token
enter the host's job environment, and the GHCR logins and the cosign binary land in the job's
temp directory, which the runner recreates for every job: the instances share one home, and
two jobs installing cosign into it at once collide ([`gotchas.md`](gotchas.md)).

A host needs rootless podman, docker (the CLI: `docker login` writes the credential cosign and
oras read), skopeo, git, jq, curl, the runner's .NET libraries (libicu, krb5-libs,
openssl-libs, zlib) and disk: 35 GB per instance at peak on the main profile, the release
profile adding the rootfs export syft reads, plus 13 GB of base image per storage. Instances
build in parallel only when each has its own container storage and its
own `TMPDIR`, both set in the runner's `.env`: the compose step prunes every unused image in
the storage it sees, and buildah keeps cache mounts under `$TMPDIR/buildah-cache-<uid>`, so
two instances sharing either delete or corrupt each other's work (measured 2026-09-04:
`podman image prune -af` removed a sibling's tagged image; two dnf caches written at once
failed the signature check). Measured the same day on a 28-thread desktop, main profile: three
instances build the three flavours in 15 minutes wall (12.9, 13.8, 14.7 min; 100 GB over the
idle disk at peak) against 26 minutes on `ubuntu-26.04`; one instance alone builds a flavour
in 8 to 11 minutes. The torn writeback of [`gotchas.md`](gotchas.md) is a property of the
runner's kernel: the post-compose probe of every main-profile run is the check a new kernel
gets.

Register as the user that owns the podman storage; the token comes from
`gh api -X POST repos/MatrixDJ96/bazzite-mx/actions/runners/registration-token --jq .token`
and lives one hour:

```bash
v=2.337.0
curl -fsSLO "https://github.com/actions/runner/releases/download/v$v/actions-runner-linux-x64-$v.tar.gz"
sha256sum -c <<< "70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613  actions-runner-linux-x64-$v.tar.gz"
d=~/actions-runner-1 && mkdir -p "$d/tmp" && tar -xzf "actions-runner-linux-x64-$v.tar.gz" -C "$d"
printf '[storage]\ndriver = "overlay"\ngraphroot = "%s"\nrunroot = "/run/user/%s/containers-runner-1"\n' ~/.local/share/containers/storage-runner-1 "$(id -u)" > "$d/storage.conf"
printf 'CONTAINERS_STORAGE_CONF=%s/storage.conf\nTMPDIR=%s/tmp\n' "$d" "$d" > "$d/.env"
"$d/config.sh" --unattended --url https://github.com/MatrixDJ96/bazzite-mx --token "$TOKEN" --name "$(hostname)-1" --labels <label> --replace
```

Each instance runs as a user service (`ExecStart=%h/actions-runner-%i/run.sh`,
`Restart=always`, lingering on), not through its `svc.sh`: a system service that executes a
script under the user's home dies at EXEC on SELinux, and rootless podman wants the user's
session. A job cancelled mid-build leaves buildah working containers behind: `buildah rm
--all` against that instance's storage once it is idle; every job ends by removing its own
images and working containers, so a storage holds only the bases between jobs (measured
2026-09-05: three jobs' leftovers, 168 GB over three storages, failed the next main-profile
run on `No space left on device`). Removal is `config.sh remove --token
<token from .../runners/remove-token>`, then the directory, the storage and the unit go.

## Keeping the pins fresh

Every third-party `uses:` is pinned to a commit SHA with the version in a trailing comment; the
repo's own reusable workflow is called by path, which GitHub cannot pin. The binaries the
workflows install take their version from an input or an env value (`cosign-release`,
`syft-version`, `ORAS_VERSION`). No bot refreshes them; `refresh-pins.sh` does, by hand:

```bash
./.github/scripts/refresh-pins.sh --self-test   # the verdicts on fixtures, offline
./.github/scripts/refresh-pins.sh --check       # one row per item, exit 0 always
./.github/scripts/refresh-pins.sh --apply       # rewrite the STALE actions and binaries
```

| Class | Item | Verdicts |
|---|---|---|
| `action` | each `uses: owner/repo[/path]@<sha> # <version>` | `OK`, `STALE`, `UNKNOWN`, `FOREIGN` |
| `binary` | `cosign-release`, `syft-version`, `ORAS_VERSION` | `OK`, `STALE`, `UNKNOWN` |
| `runner` | each `runs-on:` label against the `actions/runner-images` README | `OK`, `STALE`, `UNKNOWN` |
| `workflow` | the state of every workflow of the repository | `OK`, `DISABLED` |
| `issue` | every `owner/repo#N` cited in a workflow comment | `OK`, `CLOSED`, `UNKNOWN` |

`UNKNOWN` means no release was readable and is never taken for `OK`; `FOREIGN` means the sha is
not a commit of that repository. `--apply` rewrites the `action` and `binary` classes only: a
runner label, a disabled workflow and a closed issue each need a human call. After an apply,
lint, push to `develop`, and dispatch the main profile when `reusable-build.yml` changed. Run
`--check` whenever you touch `.github/`, and after a Fedora or Bazzite release.

## What takes the owner's OK

A push to `main`. A dispatch of `release.yml` or `promote.yml`. A delete on GHCR (`clean.yml`
with `dry_run=false`). Any change to the repository settings above, and anything that touches a
host.
