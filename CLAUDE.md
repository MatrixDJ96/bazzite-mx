# CLAUDE.md — bazzite-mx project guide

Auto-loaded by Claude Code at session start.

## Project overview

`bazzite-mx` is a personal **bootc atomic distribution** built on top of Bazzite. **Single-flavour by design**: no `IMAGE_TIER` toggle, no `-dx` suffix variants. The build pipeline is unconditional and applied always. Three GHCR images differ only in `BASE_IMAGE`:

| Image | BASE_IMAGE | Use case |
|---|---|---|
| `bazzite-mx` | `bazzite` | non-NVIDIA hardware |
| `bazzite-mx-nvidia` | `bazzite-nvidia` | NVIDIA proprietary driver |
| `bazzite-mx-nvidia-open` | `bazzite-nvidia-open` | NVIDIA open kernel modules |

**Repo**: `MatrixDJ96/bazzite-mx` on GitHub, branch `main`. SSH remote.
**Owner**: Mattia Rombi (mattyro96@gmail.com).

## Status (per phase)

| Phase | Status | Notes |
|---|---|---|
| 0 — Bootstrap | ✅ Done | Containerfile (FROM bazzite + labels) + CI workflows + cosign signing-by-digest |
| 1 — Scaffold | ✅ Done | `build_files/{shared,mx,tests}` + orchestrator (`build.sh`, `build-mx.sh`, `clean-stage.sh`, `validate-repos.sh`, `copr-helpers.sh`) + smoke-test framework (`10-tests-mx.sh` skeleton: sysctl + modules-load markers) + `.claude/` project conventions |
| 2 — Branding | ✅ Done | `00-image-info.sh` rewrites `/usr/share/ublue-os/image-info.json` (image-name, image-vendor, image-ref), `/usr/lib/os-release` VARIANT_ID, and `/etc/xdg/kcm-about-distrorc` (Variant + Website) so KDE System Settings → About reflects bazzite-mx. Smoke test asserts all four values to prevent silent regression. |
| 3 — Container runtime | ✅ Done | `10-container-runtime.sh` installs Docker CE + extras (`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`, `docker-model-plugin`) and podman extras (`podman-compose`, `podman-machine`, `podman-tui`, `podman-bootc`). `docker.socket` and `podman.socket` enabled at build. `docker-ce.repo` vendored under `system_files/etc/yum.repos.d/` with `enabled=0` and `gpgcheck=1`; `validate-repos.sh` enforces the isolation invariant. |

## Where to look

| If you need to… | Read |
|---|---|
| Understand the build flow / layout / repository structure | [`.claude/docs/architecture.md`](.claude/docs/architecture.md) |
| Write new bash, edit a script, add a third-party repo, extend smoke tests | [`.claude/docs/conventions.md`](.claude/docs/conventions.md) |
| Plan a phase, decide when to push, do a review round, handle CI | [`.claude/docs/workflow.md`](.claude/docs/workflow.md) |
| Diagnose a familiar-looking error | [`.claude/docs/gotchas.md`](.claude/docs/gotchas.md) |
| Understand how the user wants to collaborate | [`.claude/docs/preferences.md`](.claude/docs/preferences.md) |
| Pre-flight a build locally before push | [`.claude/commands/preflight.md`](.claude/commands/preflight.md) |

## Critical conventions (the absolute minimum to not break things)

1. **`dnf5 config-manager setopt <id>.enabled=0` is a SILENT NO-OP** on
   .repo files added via `addrepo --from-repofile=URL` or `--repofrompath`.
   Use `sed -i 's/^enabled=1/enabled=0/g' /etc/yum.repos.d/<file>.repo`.

2. **Every third-party `.repo` file ships `enabled=0`**. Vendor it in
   `system_files/etc/yum.repos.d/`, register the basename in
   `OTHER_REPOS` in `validate-repos.sh`, install via
   `dnf5 -y --enablerepo=<section> install <pkg>`. The validator hard-fails
   the build if a registered repo is left enabled.

3. **Pre-flight locally** with `podman build --build-arg BASE_IMAGE=bazzite …`
   **before** pushing. ~5 min vs ~15 min for a 6-job CI matrix. Always
   capture the build's exit code properly: `BUILD_EXIT=$?; exit $BUILD_EXIT`.

4. **Pause for user confirmation before push**, even on a green pre-flight.
   Push triggers 6 CI jobs and is visible to the world.

5. **Conventional Commits**. SSH for `origin` remote. Never
   `--force`, `--no-verify`, `--amend` without explicit ask.

6. **Provenance citations always**: when proposing a package or pattern,
   cite the source ("from Aurora-DX line X", "lifted from bazzite-dx",
   "my proposal validated by Y").

7. **Skip a phase when upstream handles it well**. Document why in the
   commit / status table; don't re-derive the decision next session.

For the full set of conventions (bash style, smoke test idiom, vendoring
rule, COPR pattern, comment policy), see
[`.claude/docs/conventions.md`](.claude/docs/conventions.md).

## Repository layout (one-line summary)

```
Containerfile               # 3 RUN steps: build.sh → 10-tests-mx.sh → bootc lint
build_files/{shared,mx,tests}/
system_files/{etc,usr}/
.github/workflows/          # build-stable, build-testing, reusable-build, watch-upstream
.claude/                    # this folder + settings.json + commands/preflight.md + docs/
cosign.{key,pub}            # .key gitignored
```

## Quick command cheatsheet

```bash
# Pre-flight one flavour locally (~5 min)
podman build --file Containerfile \
  --build-arg BASE_IMAGE=bazzite \
  --build-arg BASE_TAG=$(skopeo inspect --no-tags \
      docker://ghcr.io/ublue-os/bazzite:stable \
      | jq -r '.Labels["org.opencontainers.image.version"]') \
  --build-arg IMAGE_NAME=bazzite-mx \
  --tag localhost/bazzite-mx:preflight .

# Push and watch CI
git push origin main
gh run list --repo MatrixDJ96/bazzite-mx --limit 4 \
  --json databaseId,workflowName,status,conclusion,headSha,createdAt \
  | jq -r '.[] | "\(.createdAt) | \(.workflowName) | run \(.databaseId) | \(.status)/\(.conclusion // "-") | \(.headSha[0:7])"'

# Cleanup local
podman rmi localhost/bazzite-mx:preflight && podman image prune -f
```
