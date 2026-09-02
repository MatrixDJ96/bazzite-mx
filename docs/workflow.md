# Workflow

How a change reaches a host: the branches, the release run, the promotions, the recovery tools,
the repository settings the pipeline relies on, and the pin refresh. The build itself is in
[`architecture.md`](architecture.md).

Contents: branches and profiles · run the lint job locally · probe a pre-flight image by hand ·
the release run · promotions · recovery · repository settings · keeping the pins fresh ·
what takes the owner's OK.

## Branches and profiles

| Where                        | What runs                                                            | What it proves                                                     | What it publishes                 |
| ---------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------ | --------------------------------- |
| `develop`, pull requests     | the `lint` job, then the three flavours with `check-image.sh`        | the tree builds and the artefact carries what it claims            | nothing                           |
| `main`                       | the same plus the chunked image, its probe and the signing-key proof | the image a host would pull, and the key a release would sign with | nothing                           |
| `release.yml`, dispatch only | the release profile, the gate, the GitHub Release                    | see below                                                          | `:staging`, `:<tag>`, the Release |

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
gh workflow run build.yml --repo MatrixDJ96/bazzite-mx --ref main -f rechunk=true
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
              -> release_tag <fedora>.<yyyymmdd>, with .N only when that tag is already on a
              GHCR package of the repository or on a GitHub Release; a probe that fails stops
              the job, a registry and a release list with no tag at all leave the day's name
              free; a release_tag input is used as given once it has the shape
              <fedora>.<yyyymmdd>[.N], its Fedora is the base's and the same probes show it
              free (release-tag.sh --tag)
              -> resolve-base.sh --digests: the three bases read once, base_digest_<flavour>
  build       reusable-build.yml with release_tag, rechunk and publish; one job per flavour:
                build -> check-image.sh -> compose the chunked image -> check-image.sh again
                -> prove the signing key
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

The tag is the day's in UTC: `release-tag.sh` reads `date -u`, so the name rolls over at
00:00Z, not at local midnight. When the day's name is burnt (a deleted immutable release,
[`gotchas.md`](gotchas.md) § A deleted immutable release keeps its tag name burnt) or another
name is wanted, the dispatch forces it; the version job still refuses a name a package or a
release carries:

```bash
gh workflow run release.yml --repo MatrixDJ96/bazzite-mx --ref main -f reason=manual \
  -f release_tag='44.YYYYMMDD.N'
```

With `promote_stable` off, or the repository variable `PROMOTE_STABLE` not `true`, the job
prints that promotion was not requested, the gate leaves `:stable` untouched and the run is
green with the dated tag alone.

A release is cut from a commit that stays in the published history. The labels, the Release and
`changelog.sh` name the run's revision, and the next changelog lists the commits since it: a
revision folded away by a later rewrite of `main` leaves a Release pointing at a commit GitHub
no longer shows and a changelog that falls back to the whole history (`changelog.sh`,
`write_commits`). So a rewrite of `main` comes before the release it feeds, never after.

## Promotions

```bash
# move :stable onto a release a host has run and verified (ujust verify-host)
gh workflow run promote.yml --repo MatrixDJ96/bazzite-mx --ref main -f release_tag='44.YYYYMMDD'
```

`promote.yml` re-verifies the three images at `:<tag>` through `gate-release.sh promote`
(labels, negative controls, signature, attestation) and copies their digests onto `:stable`. It
shares the `bazzite-mx-release` concurrency group, so it never runs beside a release. Unlike
the `promote_stable` input of a release run, it reads no repository variable: a dispatch moves
`:stable` whatever `PROMOTE_STABLE` says, which is why it takes the owner's OK.

## Recovery: a published image without a signature

A release run that failed before the gate is dispatched again: the day's tag is still free,
since only the gate writes `:<tag>`. A re-run of the failed job rebuilds on the base of that
moment, and the gate refuses it when the base moved (`check_base` in `gate-release.sh`).

`sign-image.yml` is for a manifest pushed by hand: it signs an image of this repository by
digest and verifies it:

```bash
gh workflow run sign-image.yml --repo MatrixDJ96/bazzite-mx --ref main \
  -f image=ghcr.io/matrixdj96/PACKAGE:TAG
```

It refuses any reference outside the three packages, and it resolves the tag to a digest before
signing, because a tag can move between the two steps.

## Recovery: the signing key

A host verifies a pull of `ghcr.io/matrixdj96` against the policy and the key of the image it
booted (`/etc/pki/containers/matrixdj96.pub`), so a release signed only with a new key reaches
no host: every update fails verification and the host stays where it is. Trusting the old and
the new key at once takes `keyPaths` in the policy (containers-policy.json(5)), which
`11-image-signing.sh`, its test and `verify-host` neither write nor read: writing it before a
rotation is the owner's decision. Once `cosign.pub` is the new key, `promote.yml` refuses every
release signed with the old one, since the gate verifies against `cosign.pub`. With the old key
lost, each host installs the new public key by hand before its next update:

```bash
sudo install -m0644 NEW.pub /etc/pki/containers/matrixdj96.pub
```

## Repository settings the pipeline relies on

Checked and set with `gh`, each command run with the owner's OK.

| Setting                      | Why                                                                                                                                                                                       | Check                                                                                     | Set                                                                             |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| secret `SIGNING_SECRET`      | the cosign private key paired with `cosign.pub`                                                                                                                                           | `gh secret list`                                                                          | `gh secret set SIGNING_SECRET < key`                                            |
| variable `PROMOTE_STABLE`    | the switch of the automatic releases                                                                                                                                                      | `gh variable list`                                                                        | `gh variable set PROMOTE_STABLE --body false`                                   |
| immutable releases           | a release tag never moves, a release is never deleted, and a deleted release keeps its tag name burnt ([`gotchas.md`](gotchas.md) § A deleted immutable release keeps its tag name burnt) | `gh api repos/MatrixDJ96/bazzite-mx/immutable-releases`                                   | `gh api -X PUT repos/MatrixDJ96/bazzite-mx/immutable-releases`                  |
| default workflow permissions | the token starts read-only, each job declares what it needs                                                                                                                               | `gh api repos/MatrixDJ96/bazzite-mx/actions/permissions/workflow`                         | leave                                                                           |
| package visibility           | an anonymous host cannot pull a private image                                                                                                                                             | `gh api /user/packages/container/<package> --jq .visibility`                              | the package's settings page: the REST API has no endpoint                       |

The `gh secret` and `gh variable` lines want `--repo MatrixDJ96/bazzite-mx` outside the
checkout; the `gh api` lines name the repository in their path. GHCR creates a package private
at its first push, so the visibility row applies once per package.

## Keeping the pins fresh

Every third-party `uses:` is pinned to a commit SHA with the version in a trailing comment; the
repo's own reusable workflow is called by path, which GitHub cannot pin. The binaries the
workflows install take their version from an input or an env value (`cosign-release`,
`syft-version`, `ORAS_VERSION`). No bot refreshes them; `refresh-pins.sh` does, by hand:

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
main profile when `reusable-build.yml` changed. Run `--check` whenever you touch `.github/`,
and after a Fedora or Bazzite release. When the base moves to a new Fedora, `--check` reads
none of what moves with it: the `fedora:44` of the lint (`build.yml`, `lint-edit.sh`,
`.yamllint.yml`) and of the docs that name it, the `44.` of the tag examples, and the
`$releasever` repositories under `system_files/etc/yum.repos.d/`, Docker first, whose
`repomd.xml` for the new release has to answer before the base moves.

The `cosign-release` row is the one a bump is read before applying: v3.1.3 already deprecates
`--new-bundle-format`, and the signatures a host verifies are the layout that flag turned off
([`gotchas.md`](gotchas.md) § cosign 3.1.3 deprecates the flag the signature layout needs). The
row goes `OK` to `STALE` on the version that removes it like any other.

## What takes the owner's OK

A push to `main`. A dispatch of `release.yml`, `promote.yml` or `sign-image.yml`. A write or a
delete on GHCR (a tag moved, a version deleted). Any change to the repository settings above,
and anything that touches a host.
