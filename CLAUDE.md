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

## Status

| Phase | Status | Notes |
|---|---|---|
| 0 — Bootstrap | ✅ Done | Containerfile (FROM bazzite + labels) + CI workflows (build-stable / build-testing / reusable-build / watch-upstream) + cosign signing-by-digest |

## Conventions (the absolute minimum to not break things)

1. **Conventional Commits.** Subject ≤ 70 chars.
2. **SSH for `origin` remote.** Never `--force`, `--no-verify`, `--amend` without explicit ask.
3. **Pause for user confirmation before push.** Push triggers 6 CI jobs and is visible to the world.
4. **Pre-flight locally** with `podman build` before pushing — ~5 min vs ~15 min for a 6-job CI matrix. Always capture the build's exit code properly: `BUILD_EXIT=$?; exit $BUILD_EXIT`.

## Quick command cheatsheet

```bash
# Pre-flight one flavour locally
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
  --json databaseId,workflowName,status,conclusion,headSha,createdAt
```
