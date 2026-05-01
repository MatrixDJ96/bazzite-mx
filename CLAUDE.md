# CLAUDE.md — bazzite-mx project guide

This file is loaded automatically by Claude Code when working in this repository.
It is the canonical reference for project conventions, architecture, and "what we
already learned" so a fresh session does not re-derive things from scratch or
re-discover gotchas the hard way.

Keep this file up to date whenever a non-obvious convention is added or a new
pitfall is discovered.

---

## Project overview

`bazzite-mx` is a personal **bootc atomic distribution** built on top of Bazzite,
mirroring the Aurora-DX build style (numbered scripts per domain, isolated repos,
blocking smoke tests, targeted cleanup) and adding both Aurora-DX's superset of
DX packages and Bazzite-DX's unique gems.

**Architecture: single-flavour.** MX is a DX-tier distribution by definition —
the DX overlay is always-on. There is no `bazzite-mx` (non-DX) variant. The three
GHCR images differ only in `BASE_IMAGE`:

| Image | BASE_IMAGE | Use case |
|---|---|---|
| `bazzite-mx` | `bazzite` | non-NVIDIA hardware |
| `bazzite-mx-nvidia` | `bazzite-nvidia` | NVIDIA proprietary driver |
| `bazzite-mx-nvidia-open` | `bazzite-nvidia-open` | NVIDIA open kernel modules |

**Repo:** `MatrixDJ96/bazzite-mx` on GitHub, branch `main`. Push triggers two
workflows (`build-stable.yml`, `build-testing.yml`), each fanning out to 3 matrix
jobs → 6 jobs total per push.

**Owner:** Mattia Rombi (MatrixDJ96, mattyro96@gmail.com).

---

## Repository layout

```
bazzite-mx/
├── Containerfile                       # Single multi-stage build, 3 RUN steps
│                                       #   1. shared/build.sh (orchestrator)
│                                       #   2. tests/10-tests-dx.sh (smoke)
│                                       #   3. bootc container lint
├── build_files/
│   ├── shared/
│   │   ├── build.sh                    # Orchestrator: rsync system_files,
│   │   │                                 invoke build-dx.sh, clean-stage,
│   │   │                                 validate-repos.
│   │   ├── build-dx.sh                 # DX overlay always-on entry point.
│   │   │                                 Writes IP-forwarding sysctl + module
│   │   │                                 conf, then iterates build_files/dx/
│   │   │                                 numbered scripts in version order
│   │   │                                 (mapfile + sort -V).
│   │   ├── copr-helpers.sh             # copr_install_isolated() and
│   │   │                                 thirdparty_repo_install() helpers.
│   │   ├── clean-stage.sh              # Selective cleanup. NO `rm -rf /var`.
│   │   └── validate-repos.sh           # Repo isolation validator. Fails the
│   │                                     build if any third-party repo in
│   │                                     OTHER_REPOS is enabled=1. Includes
│   │                                     informational catch-all sweep.
│   ├── dx/
│   │   ├── 10-container-runtime.sh     # Phase 2 — Docker CE + Podman extras
│   │   │                                 + podman-bootc + sockets.
│   │   ├── 20-virtualization.sh        # Phase 3 — libvirt + qemu + virt-{
│   │   │                                 manager,viewer,install} + swtpm +
│   │   │                                 waypipe + guestfs-tools + COPR
│   │   │                                 ublue-os/packages workarounds.
│   │   ├── 30-ide.sh                   # Phase 4 — VSCode only.
│   │   └── 35-git-tools.sh             # Phase 4 — GitKraken + git-
│   │                                     credential-libsecret.
│   └── tests/
│       └── 10-tests-dx.sh              # Smoke test: rpm-q + is-enabled +
│                                         file-existence assertions per phase.
├── system_files/
│   ├── etc/
│   │   ├── skel/.config/Code/User/
│   │   │   └── settings.json           # `update.mode=none` (atomic-correct).
│   │   └── yum.repos.d/
│   │       ├── docker-ce.repo          # Vendored, enabled=0.
│   │       └── vscode.repo             # Vendored, enabled=0, gpgcheck=1.
│   └── usr/
│       ├── lib/systemd/system/
│       │   └── bazzite-mx-groups.service
│       └── libexec/
│           └── bazzite-mx-groups       # Boot-time oneshot adds wheel users
│                                         to docker + libvirt groups.
├── .github/workflows/
│   ├── build-stable.yml                # Trigger: push to main, paths-ignore
│   ├── build-testing.yml               #          docs/**, **.md, LICENSE.
│   ├── reusable-build.yml              # Matrix builder (3 flavours), buildah,
│   │                                     metadata, push, cosign-by-digest.
│   └── watch-upstream-releases.yml     # Cron: detect new Bazzite release →
│                                         re-trigger build to refresh image.
├── docs/superpowers/
│   ├── plans/2026-05-01-aurora-dx-style-porting.md   # 9-phase plan.
│   └── notes/                                         # Validation findings.
├── cosign.key  / cosign.pub             # Image signing keypair (.key gitignored).
├── README.md
└── CLAUDE.md                            # This file.
```

---

## Build commands

### Local pre-flight (single flavour, fastest feedback)

```bash
podman build \
  --file Containerfile \
  --build-arg BASE_IMAGE=bazzite \
  --build-arg BASE_TAG=44.20260501 \
  --build-arg IMAGE_NAME=bazzite-mx \
  --build-arg IMAGE_VENDOR=matrixdj96 \
  --build-arg VERSION=44.20260501 \
  --build-arg UPSTREAM_TAG=44.20260501 \
  --tag localhost/bazzite-mx:preflight \
  .
```

Resolve `BASE_TAG` to the latest stable Bazzite release tag. The other
build-args influence labels only; safe to keep static for pre-flight.

**Always check the actual exit code:** wrap with `&& echo OK` or capture
`BUILD_EXIT=$?` then `exit $BUILD_EXIT`. A naked `; echo BUILD_EXIT=$?` after
a redirected build can hide a failed build behind the always-zero echo.

### CI (auto-triggered)

`git push origin main` triggers both `build-stable.yml` and `build-testing.yml`.
Each runs 3 matrix jobs (one per flavour). Total: 6 jobs per push, ~10-15 min
wall time. Concurrency group `cancel-in-progress: true` means only the latest
push's runs are kept; intermediate pushes are auto-cancelled.

### Monitor CI

```bash
gh run list --repo MatrixDJ96/bazzite-mx --limit 4 \
  --json databaseId,workflowName,status,conclusion,headSha,createdAt \
  | jq -r '.[] | "\(.createdAt) | \(.workflowName) | run \(.databaseId) | \(.status)/\(.conclusion // "-") | \(.headSha[0:7])"'

gh run view --repo MatrixDJ96/bazzite-mx <ID> \
  --json jobs -q '.jobs[] | "\(.name) | \(.conclusion // "-")"'
```

For unattended polling: write a small bash loop to a temp file and run with
`run_in_background: true`; the harness notifies on completion.

### Local cleanup

```bash
# After a confirmed-green pre-flight, free the disk:
podman rmi localhost/bazzite-mx:preflight
podman image prune -f
```

Keep `ghcr.io/ublue-os/bazzite:<TAG>` cached as long as you're iterating —
re-pulling it costs ~3-4 minutes.

---

## Conventions established this session

### Git
- **Conventional Commits**: `feat(scope): subject`, `refactor(dx): ...`,
  `docs(plan): ...`, `ci(...)`, `fix(...)`. Subject in imperative,
  ≤ 70 chars. Body explains the why and links discoveries.
- **Co-authorship trailer** on every Claude-assisted commit:
  `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
- **SSH** for git remotes (memory-pinned user preference). HTTPS triggers
  `ksshaskpass` and breaks non-interactive pushes.
- **Never** force-push, amend, or use `--no-verify` without explicit ask.

### Bash scripts (build_files/**/*.sh)
- Header `#!/usr/bin/bash` (Bazzite ships bash here).
- `set -euxo pipefail` everywhere except `validate-repos.sh` which uses
  `set -eou pipefail` (Aurora upstream style — works because the script's
  own logic doesn't rely on `-x` tracing).
- Wrap script body with `echo "::group:: ===$(basename "$0")==="` and
  `echo "::endgroup::"` for nested log readability in GitHub Actions.
- **Do not** hide errors with `|| true` unless documented why
  (clean-stage's flatpak service mask is acceptable; install errors are not).
- Prefer arrays + loops to repeated commands.

### dnf5 quirks (PIN THESE)
- **`dnf5 config-manager setopt <repo>.enabled=0` is a SILENT NO-OP** on .repo
  files added via `addrepo --from-repofile=URL` or `--repofrompath`. It
  returns 0 and writes nothing. Use `sed -i 's/^enabled=1/enabled=0/g'
  /etc/yum.repos.d/<file>.repo` instead. This applies in
  `thirdparty_repo_install()` and to any future on-the-fly addrepo.
- **`--enablerepo=<id>`** is a runtime-only override; it does not persist
  the `enabled=1` state to disk. Safe to use for one-shot installs against
  a vendored `enabled=0` repo file.
- **`dnf` (dnf4 binary) is a compat shim** on Bazzite 44+; prefer `dnf5`
  binary for consistency. Do not mix.

### Repo isolation invariants
- Every third-party repo file in `system_files/etc/yum.repos.d/` ships
  `enabled=0`. `validate-repos.sh` enforces this for the explicit
  `OTHER_REPOS` list (docker-ce, vscode, tailscale, fedora-multimedia,
  fedora-cisco-openh264, fedora-coreos-pool, terra) and for COPR repos.
- The catch-all sweep at the bottom of `validate-repos.sh` is **informational
  only** — it lists every other `.repo` file's enabled state but does not
  fail the build, because core Fedora/Bazzite repos (`fedora.repo`,
  `fedora-updates.repo`, `terra-mesa.repo`) are legitimately `enabled=1`.
- When adding a new third-party repo: vendor the .repo file in
  `system_files/etc/yum.repos.d/` AND add its basename to `OTHER_REPOS`
  in `validate-repos.sh`.

### COPR usage
- **Always isolated.** Use `copr_install_isolated <user/copr> <packages...>`
  from `build_files/shared/copr-helpers.sh`. The function does
  `dnf5 copr enable → copr disable → install --enablerepo=<repoid>`,
  so the COPR is never globally active in the final image.
- For a `*-release` RPM that drops a .repo file (e.g. tailscale-release),
  use `thirdparty_repo_install` (5th arg overrides the file basename if
  it differs from `<repo_name>.repo`).

### Smoke tests (`build_files/tests/10-tests-dx.sh`)
- Run as a separate `RUN` step in the Containerfile, after the orchestrator
  but before `bootc container lint`. Bind-mount of `/ctx` is preserved.
- Pattern per phase: an array `<DOMAIN>_RPMS=(...)` for `rpm -q` checks,
  an array `<DOMAIN>_UNITS=(...)` for service-state checks, optional
  file-existence/content checks for system_files.
- **Service check idiom**:
  ```bash
  state=$(systemctl is-enabled "$u" 2>/dev/null || echo missing)
  if [ "$state" != "enabled" ]; then
      echo "FAIL: $u not enabled (state=$state)"
      exit 1
  fi
  ```
  `is-enabled` returns exit 0 also for `static`, `linked`, `indirect`,
  `alias` — we want `enabled` literally.

### Vendoring third-party content
- Prefer **vendored .repo files** in `system_files/` over runtime fetch.
  Auditable in git, no supply-chain surprises during builds.
- **Exception:** GitKraken — Axosoft does not publish a yum repo; we install
  via direct URL `https://release.gitkraken.com/linux/gitkraken-amd64.rpm`.
  The URL is a stable redirect to the latest version. Same trust model as
  download.docker.com (HTTPS, vendor's CDN).
- When probing third-party download URLs, use `curl -sL --range 0-1023`
  (GET partial), not `curl -I` (HEAD). Several CDNs reject HEAD; we hit
  this with GitKraken (HEAD returned 404, GET worked fine).

### Test-driven development cadence
1. Edit/add files for the new domain.
2. Local pre-flight on `bazzite` flavour (no NVIDIA): ~5 min.
3. If pre-flight green → commit (Conventional Commits).
4. Push to trigger CI matrix (3 flavours × 2 streams).
5. Monitor with a polling background bash; the harness notifies on completion.
6. Verify all 6 jobs `success`; otherwise debug from logs and iterate.

---

## Discovered gotchas (canonical list — keep growing)

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | `dnf5 config-manager setopt enabled=0` writes nothing | dnf5 5.x: setopt is no-op on .repo files added via addrepo/repofrompath | `sed -i 's/^enabled=1/enabled=0/g' <file>` |
| 2 | `curl -I https://release.gitkraken.com/...` returns 404 | Server rejects HEAD method | `curl -sL --range 0-1023` |
| 3 | Phase 1 v1 build failed: KCM branding test | `/usr/share/kcm-about-distro/kcm-about-distrorc` doesn't exist on Bazzite (Aurora-only path) | Branding made best-effort; test removed |
| 4 | Adding `swtpm-workaround.service` fails: unit not found | The `ublue-os-libvirt-workarounds` COPR consolidated this into a single `ublue-os-libvirt-workarounds.service` in v1.1+ | Don't enable the historical separate service |
| 5 | `for s in $(ls -1v ...)` brittle on edge filenames + can fail under set -e if glob empty | classic word-splitting | `mapfile -t scripts < <(find ... \| sort -V); for s in "${scripts[@]}"...` |
| 6 | Catch-all repo validator caught core Fedora repos as enabled=1 | core repos legitimately enabled | Catch-all reduced to informational logging |
| 7 | Bazzite-DX upstream sets vscode `gpgcheck=0` "FIXME signature broken" | Outdated workaround; F44/dnf5 imports the Microsoft .asc cleanly | Keep `gpgcheck=1` |
| 8 | Cockpit `cockpit.service` requires `cockpit-container.service` which doesn't exist as a file | Generated at boot from `/usr/share/containers/systemd/cockpit-container.container` quadlet via `podman-systemd-generator` | Don't fight Bazzite's design; trust their containerized cockpit |
| 9 | bootc lint warns `nonempty-boot: extlinux` after Phase 3 | qemu-system-x86-core drops an `extlinux` binary in /boot for VM bootloader templates | Non-blocking; accepted |
| 10 | `podman build … ; echo BUILD_EXIT=$?` always reports 0 | Final `echo` is the last command in the shell, its zero exit hides the build's failure | Use `&&` chain or capture with `BUILD_EXIT=$?; exit $BUILD_EXIT` |

---

## Phase status (cross-reference of `docs/superpowers/plans/`)

| Phase | Status |
|---|---|
| 1 — Scaffold | ✅ Done |
| 2 — Container runtime | ✅ Done |
| 3 — Virtualization | ✅ Done |
| 4 — IDE (vscode + git GUI) | ✅ Done |
| 5 — Cockpit | ❌ **SKIPPED** (Bazzite ships it as containerized cockpit-ws) |
| 6 — Dev/sysadmin CLI | ⏳ Todo (incl. flatpak-builder relocated from Phase 4) |
| 7 — Bazzite-DX gems | ⏳ Todo |
| 8 — Justfile + setup hooks | ⏳ Todo |
| 9 — Final hardening | ⏳ Todo |

---

## Improvements over `bazzite-dx` upstream

Cumulative wins as of 2026-05-02:

1. **Strict repo isolation** via `validate-repos.sh` + informational catch-all sweep. Upstream has no equivalent.
2. **`docker-ce.repo` vendored** in git (`system_files/etc/yum.repos.d/`). Upstream fetches it at build time from docker.com — auditable diff lost.
3. **`swtpm` always installed** for Windows-11 / TPM-aware Linux VMs. Upstream skips it implicitly via `--setopt=install_weak_deps=False` on the virt block.
4. **VSCode `gpgcheck=1`** with the Microsoft `.asc` key actually verified at install time. Upstream keeps a historical `gpgcheck=0` workaround that is no longer needed on F44 dnf5.
5. **Single-flavour MX architecture** — no IMAGE_TIER axis, simpler build matrix, simpler reasoning.
6. **`bazzite-mx-groups.service`** retroactively grants docker + libvirt groups to wheel users on first boot. Upstream's docker.socket is enabled but users have to add themselves to `docker` manually.
7. **Phase 4 split**: editor (vscode) and Git GUI (gitkraken) live in semantically separate scripts. `git-credential-libsecret` ported from Aurora base for keyring-backed git auth (not in bazzite-dx).
8. **VSCode `update.mode=none`** atomic-correct default in `/etc/skel/`. Upstream has the same setting but adds opinionated font/theme defaults; we ship only the atomic correctness fix and leave style to the user.

---

## Quick commands cheatsheet

```bash
# Pre-flight one flavour locally
cd /run/media/matrixdj96/Archivio/Projects/OS/bazzite-mx
podman build --file Containerfile \
  --build-arg BASE_IMAGE=bazzite \
  --build-arg BASE_TAG=$(skopeo inspect --no-tags \
    docker://ghcr.io/ublue-os/bazzite:stable \
    | jq -r '.Labels["org.opencontainers.image.version"]') \
  --tag localhost/bazzite-mx:preflight .

# Inspect what's in a built image
podman run --rm localhost/bazzite-mx:preflight bash -c 'rpm -q <pkg>'

# Push and watch
git push origin main
gh run watch --repo MatrixDJ96/bazzite-mx

# Check repo isolation final state from inside an image
podman run --rm localhost/bazzite-mx:preflight \
  bash -c 'grep -h "^enabled=" /etc/yum.repos.d/*.repo | sort | uniq -c'

# Rebase a deployed system onto a fresh image
sudo bootc switch ghcr.io/matrixdj96/bazzite-mx:latest
sudo bootc upgrade
sudo systemctl reboot
```

---

## When in doubt

- **Ask before pushing.** Every commit gets a "ready to push?" pause.
- **Pre-flight locally** before pushing. The user has bandwidth for it now;
  6 wasted CI jobs cost more than 5 minutes of local build.
- **Trust Bazzite's design** when it conflicts with the original plan.
  The plan was drafted from Aurora's perspective; Bazzite has its own
  (sometimes better) solutions (e.g. cockpit-as-container).
- **Verify upstream claims by reading the actual code**, not by trusting
  comments. The `gpgcheck=0` "FIXME" in bazzite-dx was outdated by years.
- **One concern per commit.** If a refactor and a feature land together,
  split into two commits with clear messages.
