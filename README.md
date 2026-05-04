# bazzite-mx

> Personal **Bazzite-based bootc atomic distribution**. KDE Plasma + container-first dev/sysadmin workstation, with curated DX tooling, hardened repo isolation, and zero-maintenance third-party integrations.

## What is bazzite-mx?

bazzite-mx is a personal fork of [Universal Blue Bazzite](https://github.com/ublue-os/bazzite) that layers a curated **developer-experience (DX) toolkit** on top of Bazzite Kinoite, taking inspiration from the build patterns of [Aurora-DX](https://github.com/ublue-os/aurora) and [Bazzite-DX](https://github.com/ublue-os/bazzite-dx) upstream.

It is a **single-maintainer project**, not a community distribution. The first-party DX images from Universal Blue (`bazzite-dx`, `aurora`/`-dx`, `bluefin`/`-dx`) are excellent and cover the same problem space; bazzite-mx exists for two narrow reasons:

- **Hardening of documented compromises.** First-party DX images ship a few patterns this fork tightens up — silent state-write race in the Bazzite-DX VSCode hook, stale `vscode.repo gpgcheck=0` workaround, non-idempotent justfile imports (see [`wins-over-upstream.md`](.claude/docs/wins-over-upstream.md) for the full list of 19 wins).
- **Opinionated personal curation.** Mozilla-RPM Firefox over Flatpak; gparted to fill the gap left by Bazzite removing `kde-partitionmanager`; no imposed fonts/themes/formatters; ujust opt-in `install-discord` / `install-1password`. None of these justify a community-scale fork; all of them justify the maintainer's own image.

A note on rpm-ostree layering: maintaining hand-rolled `rpm-ostree install` package layers manually is fragile (see Bazzite's own [docs warning](https://docs.bazzite.gg/Installing_and_Managing_Software/rpm-ostree/#major-caveats-using-rpm-ostree)). Building a custom image refreshed hourly via the upstream watcher is cleaner than re-applying layers after every reboot.

## Who is bazzite-mx for?

The target persona is **the maintainer (MatrixDJ96)**, and incidentally any user with a similar profile:

- Daily driver on Bazzite Kinoite (KDE Plasma)
- Workflow heavy with Docker / Podman / Distrobox containers
- libvirt / QEMU for occasional VMs (Windows compat, lab work)
- Code in VSCode + GitKraken
- Sysadmin / dev sensitive to image reproducibility, supply-chain auditability, and the "don't fight the atomic distro" philosophy

If you don't fit this profile, bazzite-mx might still be useful — fork freely. It is not designed to scale into a community distribution.

## Design principles

1. **Single-flavour image.** No `IMAGE_TIER` axis. Every build domain runs unconditionally on every variant. The three variants differ **only** in `BASE_IMAGE` (NVIDIA driver style).
2. **Bazzite-derived, not Bazzite-divergent.** Never override Bazzite choices we agree with (Konsole stays default terminal, ujust framework reused, no theme overrides). Only add or replace where there's clear rationale, documented in [`wins-over-upstream.md`](.claude/docs/wins-over-upstream.md).
3. **Strict repo isolation.** Every third-party `.repo` ships `enabled=0`, hard-validated at build time by `validate-repos.sh`. A leftover `enabled=1` would silently update from a third-party host on every `bootc upgrade` — breaking the reproducibility promise.
4. **Zero-maintenance third-party keys.** GPG keys for RPM Fusion (via `rpmfusion-nonfree-release` package) and 1Password (via `curl -fsSL` at build time) are not statically vendored. Static keys rot when upstream rotates them.
5. **Strictly better than Bazzite-DX upstream.** 19 documented wins as of 2026-05-04 (see [`wins-over-upstream.md`](.claude/docs/wins-over-upstream.md)). The fork exists because it can be measurably better, not for parity-of-vanity.
6. **No opinionated stylistics.** No fonts, themes, formatters, or shell preferences imposed at distro level. The user picks. (Bazzite-DX ships JetBrains Mono + Cascadia Code; AmyOS ships zsh + Ghostty + nerd fonts; we ship none of those.)

## Variants

| Image | Base | Use case |
|-------|------|----------|
| `ghcr.io/matrixdj96/bazzite-mx` | `ghcr.io/ublue-os/bazzite` | non-NVIDIA hardware |
| `ghcr.io/matrixdj96/bazzite-mx-nvidia` | `ghcr.io/ublue-os/bazzite-nvidia` | NVIDIA proprietary driver |
| `ghcr.io/matrixdj96/bazzite-mx-nvidia-open` | `ghcr.io/ublue-os/bazzite-nvidia-open` | NVIDIA open kernel modules |

Each variant is published with two stream tags: `:stable` and `:testing`.

## What's added on top of Bazzite

| Domain | What | Why |
|---|---|---|
| **Container runtime** | Docker CE + extras (compose, machine, tui, bootc) + sockets | full Docker workflow alongside Bazzite's existing Podman; isolated upstream Docker repo |
| **Virtualization** | libvirt, qemu, virt-manager, swtpm, waypipe + first-boot groups hook + `libvirtd.service` enabled at build + KVM kargs (`kvm.ignore_msrs=1` + `kvm.report_ignored_msrs=0`) shipped via `bootc/kargs.d` + flatpak virt-manager masked | Windows 11 VM compat (TPM 2.0 via swtpm) + remote-display Wayland forwarding + auto-add user to `libvirt`/`kvm` groups; the stack is fully working on first boot without `ujust setup-virtualization` (which is also overridden to remove an upstream gate that silently no-ops on RPM-installed virt-manager) |
| **Game streaming** | Sunshine (system RPM from `lizardbyte/beta` COPR) + `setcap cap_sys_admin+p` for KMS capture; user service shipped DISABLED, opt-in via `ujust setup-sunshine enable` | Bazzite removed Sunshine from base 2026-03-26 (then-stale F43 builds in the COPR) and migrated to Homebrew. The COPR resumed F44 builds 2026-04-28; we re-integrate as system RPM (Aurora pattern), avoiding the brew compile time + dependency. Updates flow with `bootc upgrade`. |
| **IDE / Dev** | VSCode (`update.mode=none` + 3 Microsoft container/remote extensions auto-installed at first user login) + GitKraken + git-credential-libsecret | atomic-correct settings (auto-update fights `/usr` read-only); same 3 extensions Aurora-DX and Bazzite-DX both converged on |
| **Dev / Sysadmin CLI** | `bcc-tools` + `bpftrace` + `bpftop` + `sysprof` + `iotop-c` + `nicstat` + `numactl` + `trace-cmd` + `flatpak-builder` + `gh` (upstream repo) + `cosign` (already in Bazzite base) | observability + container build + GitHub workflow |
| **Web / browsers** | Firefox via Mozilla RPM repo (replaces Flatpak Firefox) + Bazzite's flatpak default-install adjusted to skip Firefox | RPM Firefox supports system fonts, system policies, native messaging; Flatpak doesn't |
| **Desktop apps** | gparted (restores Bazzite-removed `kde-partitionmanager` functionality) + ptyxis (2nd container-aware terminal) | GUI partition tool back; Ptyxis as opt-in alongside Konsole, no replacement of the default |
| **ujust opt-in recipes** | `ujust install-discord` (RPM Fusion non-free) + `ujust install-1password` (vendored official repo) + `_pkg_layered` reusable helper | rpm-ostree layered installs with idempotency check; opt-in keeps metadata footprint small for users who don't want them |
| **System integration** | first-boot system-setup hooks (groups, flatpak Firefox cleanup) + first-login user-setup hooks (vscode-extensions, flatpak Firefox cleanup) — all versioned via `libsetup.sh` | bridges the `/etc/skel` doesn't-reach-existing-users gotcha; same hooks framework as Bazzite-DX, hardened against silent-disable race |
| **Branding** | image-info.json (image-name, image-vendor, image-ref) + os-release VARIANT_ID + KCM About page (Variant + Website) | clean fork identity; KDE System Settings → About correctly reflects bazzite-mx and links back to the GitHub repo |

The build is fully reproducible from the upstream Bazzite tag pin: see [Upstream watcher](#upstream-watcher) below.

## What's intentionally NOT included

| Excluded | Why |
|---|---|
| **Cockpit stack (Phase 5)** | Bazzite ships Cockpit as a podman quadlet (`quay.io/cockpit/ws:latest` with `Label=io.containers.autoupdate=registry`). Layering host-side `cockpit-*` RPMs would duplicate; `ujust cockpit enable` works as designed. |
| **Custom fonts / themes / formatters** | Stylistic choices belong to the user. Upstream Bazzite-DX ships JetBrains Mono via Brewfile + Cascadia Code as VSCode default; we don't. |
| **Zsh / Ghostty / Homebrew brewfile imports** | Opinionated developer-shell preferences. AmyOS imposes them; we keep bash + Konsole + Ptyxis as user choices. |
| **VFIO / Looking Glass / GPU passthrough** | Niche gaming/research workflow. Bazzite-DX has it; we treat it as out of scope for a daily-driver workstation. |
| **`ujust verify-image-signature` recipe** | Bazzite already ships `ujust verify-image` (different semantics: rebases to upstream-signed). Adding our own would clutter the recipe namespace. The manual `cosign verify --key cosign.pub …` documented below is sufficient. |
| **ROCm AMD GPU compute (rocm-hip / rocm-opencl / rocm-smi)** | Aurora-DX ships it conditionally (skipped on NVIDIA variants); Bazzite-DX ships it unconditionally on all variants. We omit it: ~150 MB of AMD-only libraries that would be dead weight on the two NVIDIA variants without a concrete maintainer use case. Easy to add later (or to layer per-user via `rpm-ostree install rocm-hip rocm-opencl rocm-smi`) if needed. |

## Repository layout

```
bazzite-mx/
├── Containerfile                # 3 RUN steps: build.sh → 10-tests-mx.sh → bootc lint
├── build_files/
│   ├── shared/                  # orchestrator (build.sh, build-mx.sh, copr-helpers.sh,
│   │                              clean-stage.sh, validate-repos.sh)
│   ├── mx/                      # numbered domain scripts (00-, 10-, 20-, …, 60-)
│   └── tests/
│       └── 10-tests-mx.sh       # smoke tests (blocking, rpm-q + systemctl is-enabled + content asserts)
├── system_files/                # rsync'd into / by build.sh
│   ├── etc/yum.repos.d/         # vendored .repo files (enabled=0, hard-validated)
│   ├── etc/skel/                # per-user defaults (.config/Code/...)
│   └── usr/share/ublue-os/
│       ├── just/                # 95-bazzite-mx.just (ujust install-* recipes)
│       ├── system-setup.hooks.d/  # boot-time hooks
│       └── user-setup.hooks.d/    # first-login hooks
├── .github/workflows/
│   ├── reusable-build.yml       # 3-job matrix builder (called by both stable + testing)
│   ├── build-stable.yml         # push:main + PR + dispatch → reusable(stable)
│   ├── build-testing.yml        # push:main + PR + dispatch → reusable(testing)
│   └── watch-upstream-releases.yml  # cron hourly: detect new upstream Bazzite tags
├── cosign.pub                   # public key for verifying signed images (.key gitignored)
├── CLAUDE.md                    # auto-loaded project guide for Claude Code
└── .claude/docs/                # supplementary docs (architecture, conventions,
                                   gotchas, workflow, preferences, wins-over-upstream)
```

Full architecture deep-dive: [`.claude/docs/architecture.md`](.claude/docs/architecture.md).

## Building locally

Pre-flight a single flavour before pushing to CI (~5 min on a recent laptop, vs ~15 min for the full 6-job CI matrix):

```bash
podman build --file Containerfile \
  --build-arg BASE_IMAGE=bazzite \
  --build-arg BASE_TAG=$(skopeo inspect --no-tags \
      docker://ghcr.io/ublue-os/bazzite:stable \
      | jq -r '.Labels["org.opencontainers.image.version"]') \
  --build-arg IMAGE_NAME=bazzite-mx \
  --build-arg IMAGE_VENDOR=matrixdj96 \
  --tag localhost/bazzite-mx:preflight .
```

Swap `BASE_IMAGE` to `bazzite-nvidia` or `bazzite-nvidia-open` and `IMAGE_NAME` to the matching `bazzite-mx-{nvidia,nvidia-open}` to pre-flight the other variants.

Smoke tests (`build_files/tests/10-tests-mx.sh`) run as a blocking step inside the build — a failed assertion fails the build. Authoritative conventions, gotchas, and the per-phase build-domain layout live under [`.claude/docs/`](.claude/docs/).

## Image signing

All published images are signed with `cosign` using the keypair stored in this repo (`cosign.pub`) and in the `SIGNING_SECRET` repository secret. Each successful CI build job signs the pushed image **by digest**.

To verify a deployed image (run from a clone of this repo, where `cosign.pub` lives):

```bash
cosign verify --key cosign.pub ghcr.io/matrixdj96/bazzite-mx:stable
```

The local `cosign.key` is gitignored — only present on the maintainer's machine and in GitHub repository secrets.

## Upstream watcher

`.github/workflows/watch-upstream-releases.yml` runs every hour and:

1. Fetches the latest GitHub Releases from `ublue-os/bazzite`:
   - the latest `Latest` release (stable)
   - the most recent `Pre-release` whose tag starts with `testing-`
2. Reads the `org.opencontainers.image.base.name` label from the currently published `bazzite-mx:{stable,testing}` images on GHCR.
3. For each stream where the upstream tag differs from the published label, dispatches `reusable-build.yml` pinned to the immutable upstream tag.

This keeps the published image within ≤1 hour of the upstream Bazzite release while keeping every build pinned to a specific upstream tag (reproducible, auditable).

## License

Apache-2.0 (inherited from upstream `image-template`).
