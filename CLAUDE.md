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
| 4 — Virtualization | ✅ Done | `20-virtualization.sh` installs `libvirt`, full `qemu` (system-x86, char-spice, display-virtio-{gpu,vga}, usb-redirect, user-binfmt/static), `virt-manager`, `virt-viewer`, `virt-install`, `edk2-ovmf`, `swtpm` + `swtpm-tools`, `waypipe`, `guestfs-tools`, plus the `ublue-os-libvirt-workarounds` COPR (SELinux relabel oneshot). Build-time enable of `libvirtd.service`. `system_files/usr/lib/bootc/kargs.d/01-bazzite-mx-virt.toml` ships `kvm.ignore_msrs=1` + `kvm.report_ignored_msrs=0` (Windows 11 guest-friendly). `system_files/usr/share/ublue-os/just/84-bazzite-virt.just` overrides Bazzite's upstream `setup-virtualization` recipe (drops the `! rpm -q virt-manager` gate that's permanently FALSE on our image, removes the flatpak install path; keeps VFIO / kvmfr / usbhp / group blocks). `21-virt-manager-flatpak-exclude.sh` adds `deny org.virt_manager.virt-manager/*` to `/usr/share/ublue-os/flatpak-blocklist`. Two libsetup-versioned cleanup hooks (`16-cleanup-virt-manager-flatpak.sh` system + user) flatpak-uninstall any residual flatpak namespace. |

| 5 — IDE & Git tools | ✅ Done | `30-ide.sh` installs `code` (VSCode) from vendored `vscode.repo` (`enabled=0`, `gpgcheck=1` — strictly more secure than upstream's `gpgcheck=0` workaround). `35-git-tools.sh` installs `gitkraken` (URL-fetched RPM from release.gitkraken.com, ~80 MiB) and `git-credential-libsecret` (Aurora base only, missing from Bazzite-DX). `system_files/etc/skel/.config/Code/User/settings.json` ships `{"update.mode": "none"}` so VSCode's self-updater doesn't fight a read-only `/usr` — atomic-correct default with no opinionated styling overlay. |

| 6 — Dev/sysadmin CLI | ✅ Done | `40-dev-cli.sh` installs observability + dev tooling: `android-tools`, `bcc` + **`bcc-tools`** (BPF tracing utilities — both Aurora-DX and Bazzite-DX install only `bcc` itself, missing the tools), `bpftrace`, `bpftop`, `sysprof`, `iotop-c`, `nicstat`, `numactl`, `trace-cmd`, `flatpak-builder`, `gh` (GitHub CLI from vendored `gh-cli.repo` pointing at upstream's official RPM repo — multiple minor versions ahead of Fedora's package). `cosign` is already in Bazzite base; we assert it for defensive depth. |

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
