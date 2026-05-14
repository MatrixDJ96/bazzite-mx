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

| 7 — Firefox via Mozilla RPM | ✅ Done | `45-firefox-rpm.sh` installs `firefox` + `firefox-l10n-it` from Mozilla's official RPM repo (`mozilla.repo` vendored) — replaces Bazzite's Flathub flatpak. `46-firefox-flatpak-exclude.sh` removes `org.mozilla.firefox` from Bazzite's default flatpak install list and adds `deny org.mozilla.firefox/*` to the flatpak-blocklist (Discover/Bazaar hide it). Two libsetup-versioned cleanup hooks (`15-cleanup-firefox-flatpak.sh` system + user) flatpak-uninstall any pre-existing namespace at first boot/login. |

| 8 — Third-party packages | ✅ Done | `47-rpmfusion-release.sh` installs `rpmfusion-nonfree-release` (ships GPG keys for F44/F45/F46/rawhide + the 3 `.repo` files); we sed `enabled=0` immediately. `48-1password-key.sh` fetches 1Password's official GPG key at build time (`curl -fsSL` from downloads.1password.com); `1password.repo` vendored with `enabled=0`. Both repos are runtime-enabled per-install via the `ujust install-{discord,1password}` recipes. Zero static-vendoring of GPG keys (auto-update via `bootc upgrade` for RPM Fusion's release pkg; build-time fetch refresh for 1Password). |

| 9 — Bazzite-DX gems + groups | ✅ Done | `50-bazzite-extras.sh` installs `ccache` (Bazzite-DX shipped) + the `ublue-setup-services` COPR (system-setup + user-setup hook framework with `libsetup.sh` versioning). `system_files/usr/share/ublue-os/system-setup.hooks.d/10-bazzite-mx-groups.sh` (v2) runs at first boot: appends `docker` + `libvirt` to `/etc/group` from `/usr/lib/group`, then `usermod -aG` adds wheel users to both. v2 ships alongside `system_files/usr/lib/sysusers.d/bazzite-mx-docker.conf` (`g docker -`) which compensates the rpm-ostree suppression of docker-ce's `groupadd --system docker` post-install scriptlet. |

| 10 — Justfile + ujust recipes | ✅ Done | `system_files/usr/share/ublue-os/just/95-bazzite-mx.just` ships our custom recipes: `install-discord` (RPM Fusion non-free, runtime-flips repo `enabled=0` → `enabled=1` via sed, then `rpm-ostree install discord` — mirrors Bazzite's `install-coolercontrol` idiom) + `install-1password` (vendored repo, same pattern) + `_pkg_layered` private helper (returns `yes`/`no` on stdout, idempotency check that doesn't pollute output with `just` "Recipe failed" noise). `55-justfile-import.sh` idempotently appends `import "/usr/share/ublue-os/just/95-bazzite-mx.just"` to Bazzite's master `/usr/share/ublue-os/justfile` (Bazzite uses explicit `import` directives, no glob, so unimported files are silently invisible). |

| 11 — Desktop apps + vscode extensions | ✅ Done | `60-desktop-apps.sh` installs `gparted` (restores Bazzite-removed `kde-partitionmanager` functionality — Bazzite removed the KDE GUI partition tool in commit `378e524a` Plasma 6.4 cleanup, didn't replace it) + `ptyxis` (container-aware GNOME terminal, opt-in alongside Konsole). `system_files/usr/share/ublue-os/user-setup.hooks.d/11-vscode-extensions.sh` runs at first user login and pre-installs the 3 Microsoft container/remote extensions (Aurora-DX + Bazzite-DX convergent: ms-vscode-remote.remote-containers, ms-vscode-remote.remote-ssh, ms-azuretools.vscode-containers). Hardened against `libsetup.sh::version-script` state-before-body race: every `code --install-extension` has `\|\| true` so transient marketplace timeouts don't permanently disable the hook. |

| 12 — Sunshine | ✅ Done | `65-sunshine.sh` reintegrates Sunshine as a system RPM via the `lizardbyte/beta` COPR (Bazzite removed it 2026-03-26 due to F43 stale builds; the COPR resumed F44 builds 2026-04-28). `copr_install_isolated` pattern + `setcap cap_sys_admin+p` (KMS capture) + `systemctl --global disable app-dev.lizardbyte.app.Sunshine.service` (opt-in via `ujust setup-sunshine enable`) + removal of Bazzite's `sunshine-brew.msg.json` migration nag. `system_files/usr/share/ublue-os/just/82-bazzite-sunshine.just` overrides Bazzite's brew-flavored recipe with our RPM-flavored one. |

| 13 — CI rechunker | ✅ Done | `.github/workflows/reusable-build.yml` enables `rpm-ostree compose build-chunked-oci` for the matrix. Cumulative delta over base bazzite (~80 MiB across many small files) makes semantic re-layering pay off: better resumability, smaller incremental pulls on `bootc upgrade`, lower registry storage via cross-image dedup. Cost: ~+15 min wall-clock on the 6-job matrix. Bazzite-DX/AmyOS ship this commented-out by default. |

| 14 — Release & GHCR cleanup | ✅ Done | `.github/workflows/generate-release.yml` (workflow_call) creates a GitHub Release per upstream stable bump: resolves prev release tag from the repo, pulls the 3 image digests via `skopeo inspect`, renders Markdown body through `.github/scripts/changelog.sh` (git-log + link upstream, no SBOM), then `softprops/action-gh-release@v3` (SHA-pinned) publishes. `watch-upstream.yml` chains a `release-stable` job (`needs: [check, build-stable]`) so the release fires only on actual upstream change with a green build. `.github/workflows/clean.yml` (SHA-pinned `dataaxiom/ghcr-cleanup-action@v1.0.16`) runs Sundays 00:15 UTC, prunes images >90 days, keeps last 7 tagged + 7 untagged, supports `dry_run` opt-in via dispatch. Patterns lifted from `ublue-os/bazzite` (`generate_release.yml`, `clean.yml`) — simplified (no SBOM, no Python). |

| 15 — Pipeline end-to-end (resolve → validate → build → release) | ✅ Done | `build-{stable,testing}.yml` are end-to-end and `workflow_call`-callable. Jobs: `resolve` (collision detection on `gh release list`, computes `release_tag` `<upstream_tag>(.N)?`) → `validate-just` (brew install + `just --list` on each `.just`, gates the matrix so a syntax error aborts before any GHCR push) → `build` matrix (`reusable-build.yml`, pushes immutable `:RELEASE_TAG` so `:44.20260511` retains its first-build digest after a `.1` rebuild) → `release` (`generate-release.yml` takes `stream_name`, emits stable / testing with the right `prerelease` + `make_latest` + title prefix). `watch-upstream.yml` is just a cron-fired detector that calls the two build workflows via `workflow_call`. **Permissions chain**: workflow-level `contents: write` on the three top-level workflows (otherwise the called release-publish step gets capped to `contents: read` and softprops 403s). **Concurrency**: literal kebab-case group `bazzite-mx-{stream}-${{ github.ref_name }}` with `cancel-in-progress: false` — literal because in a chained `workflow_call` the callee's `github.workflow` resolves to the caller's name, colliding with the caller's own group and producing a deadlock-cancel (empirically observed 2026-05-14); per-ref scoping lets `develop` runs proceed in parallel with `main` instead of queueing behind it. **`develop` branch policy**: push to `develop` runs `resolve`-skip + full `build` matrix with rechunk/login/push/sign/release skipped via `github.ref == default_branch` guards — sandbox for fast CI feedback without GHCR spam. Naming policy v2 enforced (Title Case workflows, sentence-case jobs/steps, SCREAMING_SNAKE_CASE env vars with no 2-3 letter sigle, snake_case canonical input/output keys with `release_tag` replacing `stream_version` everywhere). |

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

8. **CI naming conventions**: Workflow `name:` = Title Case (`Build Stable`).
   Job/step `name:` = sentence case, imperative + object (`Resolve release
   tag`, `Check just syntax`). Env vars = `SCREAMING_SNAKE_CASE` (no 2-3
   letter sigle: `DIGEST_NVIDIA_OPEN`, not `D_NVO`). Input/output keys =
   `snake_case`, no synonyms cross-workflow (`release_tag` everywhere, not
   `stream_version` in one file and `release_tag` in another). Concurrency
   `group:` = literal `bazzite-mx-<phase>[-<flavour>][-<key>]` kebab-case
   (NEVER `${{ github.workflow }}` — in any callee invoked via
   `workflow_call` it resolves to the caller's name, colliding with the
   caller's own group and triggering "deadlock detected → canceling" on
   every chained call. Empirically validated 2026-05-14). Shell binary
   names (`just`, `gh`, `podman`) lowercase, acronyms (`GHCR`, `OCI`,
   `BTRFS`, `SBOM`) uppercase.

9. **`validate-just` is a gating job inside `build-{stable,testing}.yml`**
   (not a standalone workflow). It runs `just --list` on each `.just`
   file via preinstalled brew (NOT `setup-just` or `ublue-os/just-action`;
   GitHub-hosted runners ship `just` via Linuxbrew, +30s install vs +1
   third-party action dependency — pattern aurora-conforming). The `build`
   job depends on `validate-just`, so a broken `.just` aborts the matrix
   before any GHCR push or release. Don't "modernize" this — decision
   validated by 4-lens audit + empirical gate refactor.

For the full set of conventions (bash style, smoke test idiom, vendoring
rule, COPR pattern, comment policy), see
[`.claude/docs/conventions.md`](.claude/docs/conventions.md).

## Repository layout (one-line summary)

```
Containerfile               # 3 RUN steps: build.sh → 10-tests-mx.sh → bootc lint
build_files/{shared,mx,tests}/
system_files/{etc,usr}/
.github/workflows/          # build-stable, build-testing, clean, generate-release, reusable-build, watch-upstream
.claude/                    # this folder + settings.json + commands/preflight.md + docs/
cosign.{key,pub}            # .key gitignored
```

## CI flow at a glance

```
push to main / dispatch / watch-upstream (workflow_call) ─►
  build-{stable,testing}.yml:
     resolve  (collision .N on gh release list)
       └─► build    (reusable-build, 3-image matrix, push :stable + :<release_tag> immutable)
            └─► release  (generate-release.yml, stable=latest / testing=prerelease)

watch-upstream     (cron hourly)     ─► triggers build-{stable,testing}.yml if upstream changed
clean              (cron Sun 00:15)  ─► prunes the 3 GHCR packages (>90d, keep 7+7)
generate-release   (workflow_call / dispatch) ─► takes stream_name + upstream_tag + release_tag
```

### Branch policy

| Branch | Build | Rechunk | Push GHCR | Sign | Release |
|---|---|---|---|---|---|
| `main` | ✓ | ✓ | ✓ | ✓ | ✓ (push + watch-upstream + dispatch) |
| `develop` | ✓ | ✗ | ✗ | ✗ | ✗ — fast CI sandbox |
| PR to `main` | ✓ | ✗ | ✗ | ✗ | ✗ |

Rebuild on the same upstream produces incremental tags `44.20260511.1`, `.2`, … both as GitHub Release and as immutable GHCR image tag (the original `:44.20260511` stays pinned to its first build's digest; `:stable` is mutable and always points to the latest build).

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

```bash
# Iterate WIP on the develop branch (CI runs build only — no push, no release)
git checkout -b develop
git push -u origin develop
# Then: gh run list --workflow "Build Stable" --branch develop

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
