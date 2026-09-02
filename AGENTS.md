# Project guide

Canonical, tool-agnostic instructions for any coding agent working on this repo.

## What this is

`bazzite-mx` is a personal bootc image built on Bazzite (KDE, `stable` stream). Three flavours,
`bazzite-mx`, `bazzite-mx-nvidia-open` and `bazzite-mx-nvidia`, differ only in `BASE_IMAGE`
(the closed-driver base carries its own kernel). The image is the system layer; apps are
Flatpak, CLI tools are Fedora RPMs or Homebrew, mutable userspace is distrobox. A divergence
from Bazzite enters the image only when (1) upstream does not cover it, (2) it needs the image
layer, (3) a host that runs the image uses it, (4) it ships a smoke test and cites its source.

**Repo**: `MatrixDJ96/bazzite-mx` on GitHub; images under `ghcr.io/matrixdj96/`.

## Layout

```
Containerfile               one recipe; BASE_IMAGE is the only variable
build_files/build.sh        orchestrator: NN-<feature>.sh in version order
build_files/lib/            env.sh (sourced first), log.sh, repos.sh, gpg.sh, kmod.sh,
                            just.sh, flatpak.sh
build_files/NN-<feature>.sh one script per feature (00 prep … 95 clean-stage)
build_files/tests/          run.sh (runner + pairing guard), lib.sh, one test per script
build_files/kmods/          build-kmods.sh and <name>/source.env per out-of-tree module
system_files/               copied over / by 01-system-files.sh: vendored .repo files and
                            keys, setup hooks, ujust recipes and their helpers
cosign.pub                  the key the image trusts for ghcr.io/matrixdj96
site/                       seven hand-written pages and style.css, no script, no asset
.github/scripts/            one owner per artefact, each with a --self-test
.github/workflows/          build.yml, reusable-build.yml, release.yml, promote.yml,
                            sign-image.yml, trigger-release.yml, watch-upstream.yml,
                            clean.yml, deploy-pages.yml
.claude/                    settings.json, hooks/lint-edit.sh, commands/preflight.md
docs/                       architecture, conventions, divergences, gotchas, migration,
                            workflow
```

Read `docs/architecture.md` before adding a script and `docs/conventions.md` before writing
one. What the image changes over Bazzite, and why, is `docs/divergences.md`.

## Rules

1. **Bash**: `#!/usr/bin/env bash`, `set -euo pipefail`; clean under
   `shellcheck -x -P SCRIPTDIR --severity=warning` (the sourced libraries followed) and
   `shfmt --indent 4 --case-indent --binary-next-line --space-redirects`. The shfmt release is
   Fedora 44's; CI runs it in `quay.io/fedora/fedora:44` and the edit hook does the same when
   the host binary is another minor, so hook, CI and image agree.
2. **A script that guards something ships a `--self-test`** that feeds it known-bad input and
   requires the failure (`resolve-base.sh`, `90-validate-repos.sh`, `tests/run.sh`); the lint
   job runs the CI scripts' and the runner's, the build RUNs the others (`docs/conventions.md`
   § Positive control).
   - **Every build script has a smoke test with the same stem** under `build_files/tests/`;
     `tests/run.sh` refuses the build otherwise. Tests print `OK:`/`FAIL:` lines and run
     offline on the cleaned tree.
3. **Nothing is pinned to a version** for RPMs from vendors or GitHub releases: the build
   resolves the latest release. A pin enters only against an observed problem, with the
   observation cited. The base image is the exception in the other direction: CI resolves
   `:stable` to a digest and the build pins to that digest (`resolve-base.sh`). Vendor signing
   keys are pinned on purpose: the key ships in `system_files/etc/pki/rpm-gpg/`, the `.repo`
   reads it with `gpgkey=file://`, and the feature script asserts its fingerprint before the
   first install (`assert_key_fingerprint`).
4. **Pre-flight locally** (`/preflight`, which runs `.github/scripts/preflight-build.sh`)
   before any push: the layer cache does not see a changed bind mount, so a changed script
   needs `--no-cache`; the script refuses a log without the build scripts' own output.
5. **Push to `develop` first, always.** The sandbox (`build.yml`) lints, builds the three
   flavours, probes the built image and pushes nothing. `main` adds the chunked image, its
   probe and a test signature, and takes the owner's OK; prove that profile on the branch first
   with `gh workflow run build.yml --ref <branch> -f rechunk=true`. Releases never come from a
   push (`docs/workflow.md`).
6. **Conventional Commits**, one commit per verified feature (script + test + doc together).
7. **Every entry of `docs/divergences.md` cites its source**: the upstream file, the manual
   page or the URL. A fact observed on this project carries its date, in `docs/gotchas.md`.
8. **CI naming**: workflow `name:` Title Case; job and step names sentence case, imperative +
   object; env vars `SCREAMING_SNAKE_CASE`; outputs `snake_case`, the same key everywhere;
   concurrency groups literal `bazzite-mx-<phase>[-<key>]`, never `${{ github.workflow }}` (a
   `workflow_call` callee inherits the caller's name and deadlocks on its own group).
9. **Runners and pins**: `ubuntu-26.04` for anything that needs podman, skopeo or Homebrew
   (the build jobs read `vars.BUILD_RUNNER` first, `docs/workflow.md` § A self-hosted runner
   for the build jobs); `ubuntu-slim` only for jobs that use `gh`, `jq`, `curl`. Every
   third-party `uses:` is pinned to a commit SHA with the version in a trailing comment, every
   installed binary to a version input. `./.github/scripts/refresh-pins.sh --check` opens every
   round that touches `.github/` (`docs/workflow.md` § Keeping the pins fresh).

## Cheatsheet

```bash
# Resolve the base and write the labels the way CI does
./.github/scripts/resolve-base.sh bazzite | tee /var/tmp/bazzite-mx-base.env
./.github/scripts/image-labels.sh /var/tmp/bazzite-mx-base.env "" "$(git rev-parse HEAD)" > /var/tmp/bazzite-mx-labels.txt
for s in ./.github/scripts/*.sh; do "$s" --self-test; done
./build_files/tests/run.sh --self-test
./.github/scripts/check-site.sh site

# Pre-flight one flavour: base, labels, build, log judged on the scripts' own output, probe
./.github/scripts/preflight-build.sh bazzite --no-cache

# Probe a built image the way CI does (labels, /run and /tmp, lint, packages, modules, version)
./.github/scripts/check-image.sh localhost/bazzite-mx:preflight /var/tmp/bazzite-mx-labels.txt

# Run the main profile (chunked image, probe, test signature) on a branch
gh workflow run build.yml --repo MatrixDJ96/bazzite-mx --ref develop -f rechunk=true

# Pins: the table (exit 0 always), then the rewrite of the stale actions and binaries
./.github/scripts/refresh-pins.sh --check
./.github/scripts/refresh-pins.sh --apply

# A release (owner's OK first; :stable moves only with promote_stable AND vars.PROMOTE_STABLE)
gh workflow run release.yml --repo MatrixDJ96/bazzite-mx --ref main -f reason=manual

# Lint like CI: the .sh files and the extensionless libexec helpers
scripts=$({ git ls-files '*.sh'; git grep -l '^#!/usr/bin/env bash'; } | sort -u | tr '\n' ' ')
shellcheck -x -P SCRIPTDIR --severity=warning $scripts
podman run --rm -v "$PWD:/repo:ro,z" -w /repo quay.io/fedora/fedora:44 \
  bash -c "dnf -q install -y shfmt yamllint >/dev/null; shfmt -d -i 4 -ci -bn -sr $scripts; yamllint --strict ."

# Watch CI
gh run list --repo MatrixDJ96/bazzite-mx --limit 5
```
