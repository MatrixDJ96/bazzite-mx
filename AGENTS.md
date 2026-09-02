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
Containerfile               one recipe; BASE_IMAGE is the only variable; RUN build, RUN tests, RUN lint
build_files/build.sh        orchestrator: NN-<feature>.sh in version order
build_files/lib/            env.sh (paths, sourced first), log.sh, repos.sh (install_from_repo, copr_install_isolated), gpg.sh (assert_key_fingerprint)
build_files/NN-<feature>.sh one script per feature (00 prep … 90 validate-repos, 95 clean-stage)
build_files/tests/          run.sh (runner + pairing guard) and one NN-<feature>.sh test per script
system_files/               copied over / by 01-system-files.sh, one tree for both flavours: vendored .repo files and
                            vendor keys (etc/), modules-load and setup hooks (usr/), see docs/architecture.md
cosign.pub                  the public key the image trusts for ghcr.io/matrixdj96 (11-image-signing.sh)
.github/scripts/            resolve-base.sh (base digest + kernel, one owner, --self-test)
.github/workflows/          build.yml (sandbox: lint + both flavours, no push, no release)
.claude/                    Claude Code: settings.json, hooks/lint-edit.sh, commands/preflight.md
docs/                       architecture.md (build flow, state, gates), conventions.md (bash, tests, CI, commits)
```

The remaining features and the release pipeline arrive one feature per commit; this file
grows with them. What the image changes over Bazzite, and why, is `docs/divergences.md`. Read `docs/architecture.md` before adding a
script and `docs/conventions.md` before writing one.

## Rules

1. **Bash**: `#!/usr/bin/env bash`, `set -euo pipefail`; clean under
   `shellcheck --severity=warning` and `shfmt --indent 4 --case-indent --binary-next-line --space-redirects`.
   shfmt is Fedora 44's release (3.7.0, MEASURED 2026-09-02); CI runs it in
   `quay.io/fedora/fedora:44` and the edit hook does the same when the host binary is another
   minor, so hook, CI and image agree.
2. **Every check is proven on a known-bad input before its first green run**: a script that
   guards something ships a `--self-test` that makes it fail (`resolve-base.sh`,
   `90-validate-repos.sh`, `tests/run.sh`). A green check that was never seen red proves
   nothing.
2b. **Every build script has a smoke test with the same stem** under `build_files/tests/`;
   `tests/run.sh` refuses the build otherwise. Tests print `OK:`/`FAIL:` lines and run offline
   on the cleaned tree.
3. **Nothing is pinned to a version** for RPMs from vendors or GitHub releases: the build
   resolves the latest release. A pin enters only against a measured problem, with the
   measurement cited. The base image is the exception in the other direction: CI resolves
   `:stable` to a digest and the build pins to that digest (`resolve-base.sh`). Vendor
   signing keys are pinned on purpose: the key ships in `system_files/etc/pki/rpm-gpg/`, the
   `.repo` reads it with `gpgkey=file://`, and the feature script asserts its fingerprint
   before the first install (`assert_key_fingerprint`).
4. **Pre-flight locally** (`/preflight`, `.claude/commands/preflight.md`) before any push.
   Capture the build's exit status through `PIPESTATUS`, never `tee`'s.
5. **Push to `develop` first, always.** The sandbox (`build.yml`) lints and builds both
   flavours with no GHCR push and no release. `main` runs the same sandbox with extra checks
   and takes its own explicit OK from the owner. Releases never come from a push (decision
   1.5d).
6. **Conventional Commits**, one commit per verified feature (script + test + doc together).
   Never `--force`, `--no-verify` or `--amend` without an explicit ask.
7. **Cite the source of every choice**: the upstream file and line, the manual page, the URL
   read and the date. A claim without a measurement does not close an item.
8. **CI naming**: workflow `name:` Title Case; job and step names sentence case, imperative +
   object; env vars `SCREAMING_SNAKE_CASE`; outputs `snake_case`, the same key everywhere;
   concurrency groups literal `bazzite-mx-<phase>[-<key>]`, never `${{ github.workflow }}` (a
   `workflow_call` callee inherits the caller's name and deadlocks on its own group).
9. **Runners**: `ubuntu-26.04` for anything that needs podman, skopeo or Homebrew;
   `ubuntu-slim` only for jobs that use `gh`, `jq`, `curl`. Every `uses:` is pinned to a commit
   SHA with the version in a trailing comment.

## Cheatsheet

```bash
# Resolve the base the way CI does
./.github/scripts/resolve-base.sh bazzite            # prints base_image=... kernel_version=...
./.github/scripts/resolve-base.sh --self-test        # must print "self-test ok"

# Lint like CI
scripts=$({ git ls-files '*.sh'; git grep -l '^#!/usr/bin/env bash'; } | sort -u | tr '\n' ' ')   # .sh files and the libexec helpers
shellcheck -x -P SCRIPTDIR --severity=warning $scripts                          # -x -P: follow the sourced libraries
podman run --rm -v "$PWD:/repo:ro,z" -w /repo quay.io/fedora/fedora:44 \
  bash -c "dnf -q install -y shfmt yamllint >/dev/null; shfmt -d -i 4 -ci -bn -sr $scripts; yamllint --strict ."

# Watch CI
gh run list --repo MatrixDJ96/bazzite-mx --limit 5
```
