# AGENTS.md — bazzite-mx project guide

Canonical, tool-agnostic instructions for any coding agent working on this repo.

## Project overview

`bazzite-mx` is a personal **bootc atomic distribution** built on top of Bazzite.
**Single-flavour by design**: no `IMAGE_TIER` toggle, no `-dx` suffix variants. The build
pipeline is unconditional and applied always. Three GHCR images differ only in `BASE_IMAGE`:

| Image | BASE_IMAGE | Use case |
|---|---|---|
| `bazzite-mx` | `bazzite` | non-NVIDIA hardware |
| `bazzite-mx-nvidia` | `bazzite-nvidia` | NVIDIA proprietary driver |
| `bazzite-mx-nvidia-open` | `bazzite-nvidia-open` | NVIDIA open kernel modules |

**Repo**: `MatrixDJ96/bazzite-mx` on GitHub, branch `main`. **Owner**: Mattia Rombi
(mattyro96@gmail.com).

## Where to look

| If you need to… | Read |
|---|---|
| Understand the build flow / layout / repository structure | [`docs/architecture.md`](docs/architecture.md) |
| Write new bash, edit a script, add a third-party repo, extend smoke tests | [`docs/conventions.md`](docs/conventions.md) |
| Plan a phase, decide when to push, do a review round, handle CI | [`docs/workflow.md`](docs/workflow.md) |
| Check whether the action pins / cosign / runner labels have gone stale (no bot does it) | [`docs/workflow.md`](docs/workflow.md) § Keeping the pins fresh |
| Diagnose a familiar-looking error | [`docs/gotchas.md`](docs/gotchas.md) |
| Understand what bazzite-mx intentionally changes over upstream (+ design philosophy) | [`docs/divergences.md`](docs/divergences.md) |

## Critical conventions (the absolute minimum to not break things)

1. **`dnf5 config-manager setopt <id>.enabled=0` is a SILENT NO-OP** on .repo files added via
   `addrepo --from-repofile=URL` or `--repofrompath`. Use
   `sed -i 's/^enabled=1/enabled=0/g' /etc/yum.repos.d/<file>.repo`.

2. **Every third-party `.repo` file ships `enabled=0`**. Vendor it in
   `system_files/etc/yum.repos.d/`, register the basename in
   `build_files/shared/third-party-repos.list`, install via
   `dnf5 -y install --enablerepo=<section> <pkg>`. The validator hard-fails the build if a
   **registered** repo is left enabled OR is listed but absent from the image (a base rename
   must be mirrored in the list; `?` prefix = optional entry, enforced only when present) —
   registration is the load-bearing step, because its catch-all sweep over the remaining
   `.repo` files only lists them, so an unregistered repo left `enabled=1` ships silently.

3. **Pre-flight locally** with `podman build --build-arg BASE_IMAGE=bazzite …` **before**
   pushing. ~5 min vs ~15 min for a 6-job CI matrix. Always capture the build's exit code
   properly: `BUILD_EXIT=$?; exit $BUILD_EXIT`.

4. **Push to `develop` FIRST, always** (owner's standing instruction, 2026-08-28): the sandbox
   run (3 flavours × 2 streams + integrity check + its self-test, no rechunk) validates a change in ~10 min of
   wall-clock (MEASURED 2026-09-01 on ubuntu-26.04, run 33537087404: 10m27s, the jobs run in parallel)
   before the main matrix spends any rechunk minute. Rechunk-gated behaviour (compose flags,
   label stamping) is outside the sandbox's reach: its proof lands on the first main run, and
   the push proposal names that residual. `main` is proposed only after the sandbox is green,
   and **takes its own user confirmation**, even on a green pre-flight: it triggers the 6-job
   matrix and is visible to the world. Never offer a direct main push as the first option.

5. **Conventional Commits**. Never `--force`, `--no-verify`, `--amend` without explicit ask.

6. **Provenance citations always**: when proposing a package or pattern, cite the source ("from
   Aurora-DX line X", "lifted from bazzite-dx", "my proposal validated by Y").

7. **Skip a phase when upstream handles it well**. Document why in the commit message and in
   `docs/divergences.md`; don't re-derive the decision next session.

8. **CI naming conventions**: Workflow `name:` = Title Case (`Build Bazzite-MX`). Job/step
   `name:` = sentence case, imperative + object (`Resolve release tag`, `Check just syntax`).
   Env vars = `SCREAMING_SNAKE_CASE` (no 2-3 letter sigle: `DIGEST_NVIDIA_OPEN`, not `D_NVO`).
   Input/output keys = `snake_case`, no synonyms cross-workflow (`release_tag` everywhere, not
   `stream_version` in one file and `release_tag` in another). Concurrency `group:` = literal
   `bazzite-mx-<phase>[-<flavour>][-<key>]` kebab-case (NEVER `${{ github.workflow }}` — in any
   callee invoked via `workflow_call` it resolves to the caller's name, colliding with the
   caller's own group and triggering "deadlock detected → canceling" on every chained call.
   Empirically validated 2026-05-14). Shell binary names (`just`, `gh`, `podman`) lowercase,
   acronyms (`GHCR`, `OCI`, `BTRFS`, `SBOM`) uppercase.

9. **A base-image file modified in place needs a fresh-inode rewrite**. The runner kernel loses
   writeback of writes into copied-up overlay files, so `>>`, `cat tmp > file`, `cp src dst`,
   `tee`, `curl -o` and sqlite writes ship a NUL tail while the build stays green (gotcha #34).
   Close such a script with `rewrite_fresh_inode` from
   `build_files/shared/writeback-helpers.sh`; `sed -i`, `install`, `mv`, `rsync` and `depmod`
   already rename onto a fresh inode. The cold post-rechunk counterpart is
   `.github/scripts/check-image-integrity.sh`, and every probe added to it is proven on a
   known-bad input first.

10. **`validate-just` is a gating job inside `build.yml`** (not a standalone
    workflow). It runs `just --list` on each `.just` file, installing `just` through the
    runner's preinstalled Linuxbrew (NOT `setup-just` or `ublue-os/just-action`: +30s install
    vs one more third-party action dependency — pattern aurora-conforming). The `build` job
    depends on `validate-just`, so a broken `.just` aborts the matrix before any GHCR push or
    release. Don't "modernize" this — decision validated by 4-lens audit + empirical gate
    refactor.

For the full set of conventions (bash style, smoke test idiom, vendoring rule, COPR pattern,
comment policy), see [`docs/conventions.md`](docs/conventions.md).

## Repository layout (one-line summary)

```
AGENTS.md                   # canonical project guide (this file)
CLAUDE.md                   # Claude Code bridge → @AGENTS.md
Containerfile               # 3 RUN steps: build.sh → 10-tests-mx.sh → bootc lint
build_files/{shared,mx,tests,kmods}/
system_files/{etc,usr}/
site/                       # GitHub Pages landing page (index.html + assets)
docs/                       # deep knowledge: architecture, conventions, gotchas, workflow, divergences
.github/workflows/          # build, clean, deploy-pages, generate-release, reusable-build, sign-image, watch-upstream
.github/scripts/            # changelog.sh (release notes) + list-flavours.sh (the flavour set, one owner) + resolve-upstream-tag.sh (latest upstream tag, one owner) + resolve-release-tag.sh + resolve-kernel-coords.sh (akmods carrier flavour) + check-image-integrity.sh (cold post-rechunk + --self-test) + promote-release-tags.sh / verify-published-signatures.sh (per-stream gate + signature proof)
.claude/                    # Claude Code config: settings.json + commands/preflight.md + hooks/shellcheck-edit.sh (+ gitignored local state: settings.local.json, audits/, sessions/)
cosign.{key,pub}            # .key gitignored
```

## CI flow at a glance

```
push to main / dispatch / watch-upstream (workflow_call) ─►
  build.yml  (ONE run, both streams):
     plan     (stream set → matrix_include JSON: 3 flavours × selected streams)
     validate-just
       └─► resolve-{stable,testing}  (collision .N on gh release list + GHCR tags)
             └─► build  (reusable-build called ONCE: single 6-job matrix, rechunk + cold integrity check, staging push + sign per flavour)
                  └─► promote-{stable,testing}  (per-stream gate: manifest count vs matrix_include; moves :<stream>/:<stream>-44/:latest and adds :<release_tag>, digest-copied)
                       └─► verify-{stable,testing} ─► gate  (emits stable_ok / testing_ok)
                            └─► release-{stable,testing}  (generate-release.yml, gated on <stream>_ok — from build onward one broken stream never sinks the other; a FAILED resolve job stops the whole run by design; stable=latest / testing=prerelease)

watch-upstream     (cron hourly)     ─► triggers build.yml (streams=both|stable|testing) if upstream changed
clean              (cron Sun 00:15)  ─► prunes the GHCR packages of list-flavours.sh (>90d, keep 7+7, moving aliases exempt)
generate-release   (workflow_call / dispatch) ─► takes stream_name + upstream_tag + release_tag
sign-image         (dispatch)        ─► signs an already-published image by digest, then verifies it
```

### Branch policy

| Branch | Build | Rechunk | Push GHCR | Sign | Release |
|---|---|---|---|---|---|
| `main` | ✓ | ✓ | ✓ | ✓ | ✓ (push + watch-upstream + dispatch) |
| `develop` | ✓ 6 jobs (3 flavours × 2 streams) + sandbox integrity check | ✗ | ✗ | ✗ | ✗ — fast CI sandbox |
| PR to `main` | ✓ 6 jobs (3 flavours × 2 streams) + sandbox integrity check | ✗ | ✗ | ✗ | ✗ |

Release tags carry the **build date**, not the upstream tag's date: `44.<build date>` for
stable, `testing-44.<build date>` for testing, with `.1`, `.2`, … appended on same-day rebuilds
— so upstream's own `.N` rebuild suffixes never leak into our nomenclature. Each release tag
exists both as GitHub Release and as a GHCR tag the CI never re-points; the moving aliases
(`:stable`, `:testing`, `:latest`, `:<stream>-44`) and the CI-internal `:staging-<stream>`
hand-off tags have no Release of their own (full tag table in README § The images); the
upstream tag a release was built off is recorded in the release title
(`44.20260706: Stable (Bazzite 44.20260629)`).

## Quick command cheatsheet

```bash
# Pre-flight one flavour locally (~5 min): run /preflight (.claude/commands/preflight.md);
# the full manual podman recipe lives in README.md § "How it's built and shipped".

# Push and watch CI
git push MatrixDJ96 main
gh run list --repo MatrixDJ96/bazzite-mx --limit 4 \
  --json databaseId,workflowName,headBranch,status,conclusion,headSha,createdAt \
  | jq -r '.[] | "\(.createdAt) | \(.workflowName) | \(.headBranch) | run \(.databaseId) | \(.status)/\(.conclusion // "-") | \(.headSha[0:7])"'

# Cleanup local (scoped: a bare `podman image prune -f` also takes unrelated dangling images)
podman rmi localhost/bazzite-mx:preflight
podman image prune -f --filter label=org.opencontainers.image.title=bazzite-mx
```

```bash
# Iterate WIP on develop (CI: 6 jobs, 3 flavours × 2 streams + integrity check — no push, no release)
git checkout develop
git push MatrixDJ96 develop
# Then: gh run list --workflow "Build Bazzite-MX" --branch develop

# Trigger a release manually (stream defaults to stable, upstream auto-resolves latest)
gh workflow run "Generate Release" --repo MatrixDJ96/bazzite-mx \
  -f stream_name=stable
# Force a testing pre-release for the latest upstream testing tag:
gh workflow run "Generate Release" --repo MatrixDJ96/bazzite-mx \
  -f stream_name=testing

# List published releases on the repo
gh release list --repo MatrixDJ96/bazzite-mx

# Preview what the weekly GHCR cleanup would prune (no destructive action)
gh workflow run "Cleanup GHCR" --repo MatrixDJ96/bazzite-mx -f dry_run=true
```
