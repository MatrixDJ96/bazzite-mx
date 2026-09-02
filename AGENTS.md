# AGENTS.md — bazzite-mx project guide

Canonical, tool-agnostic instructions for any coding agent working on this repo.

## What this is

`bazzite-mx` is a personal bootc image built on Bazzite (KDE, `stable` stream). Two flavours,
`bazzite-mx` and `bazzite-mx-nvidia-open`, differ only in `BASE_IMAGE`. The image is the system
layer; apps are Flatpak, CLI tools are Fedora RPMs or Homebrew, mutable userspace is distrobox.
A divergence from Bazzite enters the image only when (1) upstream does not cover it, (2) it
needs the image layer, (3) a host of the fleet uses it, (4) it ships a smoke test and cites its
source.

**Repo**: `MatrixDJ96/bazzite-mx` on GitHub. **Owner**: Mattia Rombi.

## Layout

```
Containerfile               one recipe; BASE_IMAGE is the only variable; kmod-builder stage, then RUN build, RUN tests, RUN lint
build_files/build.sh        orchestrator: NN-<feature>.sh in version order
build_files/lib/            env.sh (paths, sourced first), log.sh, repos.sh (install_from_repo, copr_install_isolated), gpg.sh (KEY_FPR table, assert_key_fingerprint),
                            kmod.sh (kernel_version, assert_module: the kmod stage and 50-kmods.sh), just.sh (recipe_set, has_recipe)
build_files/NN-<feature>.sh one script per feature (00 prep … 90 validate-repos, 95 clean-stage)
build_files/tests/          run.sh (runner + pairing guard), lib.sh (check_pkg, check_unit_state, check_desktop_file, check_just_fmt,
                            check_recipe_help) and one NN-<feature>.sh test per script
build_files/kmods/          build-kmods.sh (kmod-builder stage, --self-test) and <name>/source.env per module (URL, pinned COMMIT)
system_files/               copied over / by 01-system-files.sh, one tree for both flavours: vendored .repo files and
                            vendor keys (etc/), modules-load, setup hooks, ujust recipes, their helpers and the host.sh they share (usr/),
                            see docs/architecture.md
cosign.pub                  the public key the image trusts for ghcr.io/matrixdj96 (11-image-signing.sh)
site/index.html             the landing page (one file: images, switch commands, signature check), published by deploy-pages.yml
.github/scripts/            resolve-base.sh (base digest + kernel), image-labels.sh (the labels file), check-image.sh (probe of the built image),
                            release-tag.sh (the release tag), gate-release.sh (verify by digest, tag, promote), changelog.sh (release notes),
                            refresh-pins.sh (pin refresh), watch-upstream.sh (the watcher's verdict and dispatch decision),
                            check-site.sh (the landing page), install-oras.sh (the ORAS CLI from its release, checksum
                            verified), lib.sh (coordinates, fail/err/emit, read_env, TAG_SHAPE: sourced by all); each one
                            owner, each --self-test (run by the lint job)
.github/workflows/          build.yml (lint, then reusable-build.yml: sandbox profile on develop/PR, main profile on main or dispatch `rechunk`),
                            reusable-build.yml (both flavours; publish only from release.yml), release.yml (dispatch only: version, build,
                            gate, release), promote.yml (move :stable), sign-image.yml (recovery signer),
                            trigger-release.yml (weekly cron → release.yml), watch-upstream.yml (6-hourly cron: base digest vs our :stable →
                            release.yml), clean.yml (GHCR retention, dispatch with dry_run), deploy-pages.yml (site/ to
                            GitHub Pages on a push to main)
.claude/                    Claude Code: settings.json, hooks/lint-edit.sh, commands/preflight.md
docs/                       architecture.md (build flow, state, gates, CI), conventions.md (bash, tests, CI, commits), divergences.md (what changes over Bazzite, why),
                            gotchas.md (measured facts), migration.md (moving a host to v2), workflow.md (branches, the release run, cutover, repo settings, pins)
```

The remaining features and the release pipeline arrive one feature per commit; this file grows
with them. What the image changes over Bazzite, and why, is `docs/divergences.md`. Read
`docs/architecture.md` before adding a script and `docs/conventions.md` before writing one.

## Rules

1. **Bash**: `#!/usr/bin/env bash`, `set -euo pipefail`; clean under
   `shellcheck -x -P SCRIPTDIR --severity=warning` (the sourced libraries followed) and
   `shfmt --indent 4 --case-indent --binary-next-line --space-redirects`. shfmt is Fedora 44's
   release (3.7.0, MEASURED 2026-09-02); CI runs it in `quay.io/fedora/fedora:44` and the edit
   hook does the same when the host binary is another minor, so hook, CI and image agree.
2. **Every check is proven on a known-bad input before its first green run**: a script that
   guards something ships a `--self-test` that makes it fail (`resolve-base.sh`,
   `90-validate-repos.sh`, `tests/run.sh`). A green check that was never seen red proves
   nothing.
   - **Every build script has a smoke test with the same stem** under `build_files/tests/`;
     `tests/run.sh` refuses the build otherwise. Tests print `OK:`/`FAIL:` lines and run
     offline on the cleaned tree.
3. **Nothing is pinned to a version** for RPMs from vendors or GitHub releases: the build
   resolves the latest release. A pin enters only against a measured problem, with the
   measurement cited. The base image is the exception in the other direction: CI resolves
   `:stable` to a digest and the build pins to that digest (`resolve-base.sh`). Vendor signing
   keys are pinned on purpose: the key ships in `system_files/etc/pki/rpm-gpg/`, the `.repo`
   reads it with `gpgkey=file://`, and the feature script asserts its fingerprint before the
   first install (`assert_key_fingerprint`).
4. **Pre-flight locally** (`/preflight`, `.claude/commands/preflight.md`) before any push.
   Capture the build's exit status through `PIPESTATUS`, never `tee`'s.
5. **Push to `develop` first, always.** The sandbox (`build.yml`) lints and builds both
   flavours, probes the built image (`check-image.sh`) and pushes nothing. `main` adds the
   chunked image a host would pull, its probe and a test signature with the repo's key, and
   takes its own explicit OK from the owner; that profile is proven first on the branch with
   `gh workflow run build.yml --ref <branch> -f rechunk=true`. Releases never come from a push
   (decision 1.5d): `release.yml` is dispatch-only, and its dispatch, like `promote.yml`'s,
   takes the owner's OK (`docs/workflow.md`).
6. **Conventional Commits**, one commit per verified feature (script + test + doc together).
   Never `--force`, `--no-verify` or `--amend` without an explicit ask.
7. **Cite the source of every choice**: the upstream file and line, the manual page, the URL
   read and the date. A claim without a measurement does not close an item.
8. **CI naming**: workflow `name:` Title Case; job and step names sentence case, imperative +
   object; env vars `SCREAMING_SNAKE_CASE`; outputs `snake_case`, the same key everywhere;
   concurrency groups literal `bazzite-mx-<phase>[-<key>]`, never `${{ github.workflow }}` (a
   `workflow_call` callee inherits the caller's name and deadlocks on its own group).
9. **Runners and pins**: `ubuntu-26.04` for anything that needs podman, skopeo or Homebrew;
   `ubuntu-slim` only for jobs that use `gh`, `jq`, `curl`. Every `uses:` is pinned to a commit
   SHA with the version in a trailing comment, every installed binary to a version input.
   `./.github/scripts/refresh-pins.sh --check` opens every round that touches `.github/`
   (`docs/workflow.md` § Keeping the pins fresh); no bot refreshes them.

## Cheatsheet

```bash
# Resolve the base and write the labels the way CI does
./.github/scripts/resolve-base.sh bazzite | tee /var/tmp/bazzite-mx-base.env   # base_image=... kernel_version=...
./.github/scripts/image-labels.sh /var/tmp/bazzite-mx-base.env "" "$(git rev-parse HEAD)" > /var/tmp/bazzite-mx-labels.txt
for s in ./.github/scripts/*.sh; do "$s" --self-test; done                        # every CI script proves it fails closed
./.github/scripts/check-site.sh site                                            # the landing page, links included

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
