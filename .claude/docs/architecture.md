# Architecture

## What `bazzite-mx` is

A personal **bootc atomic distribution** built on top of upstream Bazzite,
adopting the Aurora-DX build style (numbered scripts per domain, isolated
repos, blocking smoke tests, targeted cleanup) and adding both Aurora-DX's
superset of DX packages and Bazzite-DX's unique gems.

## Single-flavour design

bazzite-mx is single-flavour **by definition**. There is no `IMAGE_TIER` toggle,
no `-dx` suffix variant, and no separate "lite" image — every build step in
`build_files/mx/` runs unconditionally on every image. The three GHCR images
differ **only** in `BASE_IMAGE`:

| Image | BASE_IMAGE | Use case |
|---|---|---|
| `bazzite-mx` | `bazzite` | non-NVIDIA hardware |
| `bazzite-mx-nvidia` | `bazzite-nvidia` | NVIDIA proprietary driver |
| `bazzite-mx-nvidia-open` | `bazzite-nvidia-open` | NVIDIA open kernel modules |

The original plan v1 had an `IMAGE_TIER=base|dx` axis. It was removed early in
the session — see commit `98dcba3 refactor(dx): collapse to single MX flavour
(always-DX)`.

## Containerfile flow

The Containerfile has 3 `RUN` steps after the `FROM` directive:

1. **`/ctx/build_files/shared/build.sh`** — orchestrator that (a) rsyncs
   `system_files/` into `/`, (b) calls `build-mx.sh`, (c) runs `clean-stage.sh`,
   (d) runs `validate-repos.sh`. Mounts a build context bind, plus `/var/cache`
   and `/var/log` as caches and `/tmp` as tmpfs.
2. **`/ctx/build_files/tests/10-tests-mx.sh`** — smoke test (rpm-q +
   systemctl is-enabled + file-existence assertions). Bind-mount of `/ctx`
   preserved so the test can read the build context if needed.
3. **`bootc container lint`** — strict (no `|| true`). The image cannot ship
   with hard lint failures.

## Build orchestration order

Inside `build.sh`:

```
rsync system_files/ → /
  └─ vendored .repo files land at /etc/yum.repos.d/<x>.repo (enabled=0)
  └─ /etc/skel/.config/Code/User/settings.json
  └─ /usr/lib/systemd/system/bazzite-mx-groups.service
  └─ /usr/libexec/bazzite-mx-groups
build-mx.sh
  ├─ writes /etc/sysctl.d/90-bazzite-mx-forwarding.conf
  ├─ writes /etc/modules-load.d/90-bazzite-mx.conf
  └─ enumerate build_files/mx/[0-9]*-*.sh in version order
       (mapfile -t < <(find … | sort -V))
       │
       ├─ 10-container-runtime.sh   (Phase 2)
       ├─ 20-virtualization.sh      (Phase 3)
       ├─ 30-ide.sh                 (Phase 4)
       └─ 35-git-tools.sh           (Phase 4)
clean-stage.sh
  ├─ dnf5 config-manager setopt keepcache=0
  ├─ dnf5 versionlock clear
  ├─ mask + remove flatpak-add-fedora-repos.service
  ├─ rm /.gitkeep
  ├─ find /var/* -maxdepth 0 -type d ! -name cache -exec rm -fr {} \;
  └─ mkdir /var/tmp
validate-repos.sh
  ├─ check COPR globs (_copr:..., _copr_...) → all enabled=0
  ├─ check OTHER_REPOS list → all enabled=0
  ├─ check rpmfusion-* → all enabled=0
  └─ informational catch-all (no fail)
```

## Repository layout

```
bazzite-mx/
├── Containerfile                # 3-stage: ctx + base + final
├── build_files/
│   ├── shared/                  # Orchestrator + helpers (build.sh,
│   │                              build-mx.sh, copr-helpers.sh,
│   │                              clean-stage.sh, validate-repos.sh)
│   ├── mx/                      # Numbered domain scripts (00-, 10-, 20-, 30-, 35-, …)
│   └── tests/                   # 10-tests-mx.sh (smoke)
├── system_files/                # Rsync'd into / by build.sh
│   ├── etc/yum.repos.d/         # Vendored .repo files (enabled=0)
│   ├── etc/skel/                # Per-user defaults (.config/Code/...)
│   └── usr/lib/systemd/system/  # bazzite-mx-* units
│       └── /usr/libexec/        # bazzite-mx-* helper scripts
├── .github/workflows/
│   ├── build-stable.yml         # push → 3-job matrix on stable Bazzite
│   ├── build-testing.yml        # push → 3-job matrix on testing Bazzite
│   ├── reusable-build.yml       # the actual builder (matrix, buildah,
│   │                              metadata, push, cosign-by-digest)
│   └── watch-upstream-releases.yml  # daily cron, refreshes on new Bazzite
├── docs/superpowers/
│   ├── plans/                   # Long-form implementation plans
│   └── notes/                   # Validation notes (Aurora, Bazzite, Bazzite-DX)
├── cosign.key  + cosign.pub     # .key gitignored
├── CLAUDE.md                    # Auto-loaded project guide (slim)
└── .claude/                     # Project Claude Code config
    ├── settings.json            # Permissions allowlist/denylist
    ├── commands/preflight.md    # /preflight slash command
    └── docs/                    # This folder
```

## CI matrix

`.github/workflows/reusable-build.yml` is called by both `build-stable.yml` and
`build-testing.yml`. Each parent workflow passes a different `stream_name`
("stable" or "testing"), and reusable-build resolves the upstream tag accordingly:

- **stable**: latest GitHub release of `ublue-os/bazzite` with no prefix
  (e.g. `44.20260501`).
- **testing**: latest tag starting with `testing-` (e.g. `testing-45.20260430`).

The matrix is 3 jobs: `bazzite`, `bazzite-nvidia`, `bazzite-nvidia-open`. So
each push triggers **6 jobs total** (3 × 2 streams).

`concurrency.cancel-in-progress: true` means a new push to `main` cancels any
in-flight runs for the same workflow + ref + stream — only the latest commit's
runs survive.

## Cockpit pattern (why we don't ship cockpit-machines)

Bazzite ships cockpit as a **podman quadlet** at `/usr/share/containers/systemd/cockpit-container.container`:

```
[Container]
Image=quay.io/cockpit/ws:latest
Volume=/:/host
PodmanArgs=--privileged --pid=host --cgroups=split
```

systemd's `podman-systemd-generator` reads this at boot and creates
`cockpit-container.service` dynamically in `/run/systemd/system/`. The
`cockpit.service` stub at `/usr/lib/systemd/system/cockpit.service` (custom-
injected by Bazzite, not owned by any RPM) just `Requires=cockpit-container.service`.

`ujust cockpit enable` toggles the stub → starts the container → user gets a
full Cockpit UI at https://localhost:9090 with all standard modules bundled in
`quay.io/cockpit/ws:latest` and auto-updates via
`Label=io.containers.autoupdate=registry`.

Adding host-side `cockpit-machines` or `cockpit-ostree` RPMs would duplicate
what the container already serves. Phase 5 of the original plan is therefore
**SKIPPED**.

## Repo isolation invariant

Every third-party repository file (`docker-ce.repo`, `vscode.repo`, etc.) ships
to the image with `enabled=0`. `validate-repos.sh` enforces this for an explicit
list of known repos AND surveys all `.repo` files informationally for visibility.
Installing packages from a "disabled" repo is done via the runtime-only override
`dnf5 -y --enablerepo=<id> install <pkg>`, which does not modify the file's
on-disk state. A post-install `bootc upgrade` will therefore never silently pull
updates from a third-party host.

For COPR: the `copr_install_isolated` helper in `build_files/shared/copr-helpers.sh`
implements the same pattern — `dnf5 copr enable → copr disable → install --enablerepo=`.

See [`conventions.md`](conventions.md) for the **dnf5 setopt no-op gotcha** that
makes `sed -i 's/^enabled=1/enabled=0/g'` the canonical way to neutralize a
runtime-added .repo file.
