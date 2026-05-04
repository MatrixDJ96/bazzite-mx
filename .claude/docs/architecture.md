# Architecture

## What `bazzite-mx` is

A personal **bootc atomic distribution** built on top of upstream Bazzite,
adopting the Aurora-DX build style (numbered scripts per domain, isolated
repos, blocking smoke tests, targeted cleanup).

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
build-mx.sh
  ├─ writes /etc/sysctl.d/90-bazzite-mx-forwarding.conf
  ├─ writes /etc/modules-load.d/90-bazzite-mx.conf
  └─ enumerate build_files/mx/[0-9]*-*.sh in version order
       (mapfile -t < <(find … | sort -V))
       │
       └─ (no domain scripts yet at scaffold time)
clean-stage.sh
  ├─ dnf5 config-manager setopt keepcache=0
  ├─ dnf5 versionlock clear
  ├─ mask + remove flatpak-add-fedora-repos.service
  ├─ rm /.gitkeep
  ├─ find /var/* -maxdepth 0 -type d ! -name cache -exec rm -fr {} \;
  └─ mkdir /var/tmp
validate-repos.sh
  └─ (no third-party repos tracked yet at scaffold time)
```

## Repository layout

```
bazzite-mx/
├── Containerfile                # 3-stage: ctx + base + final
├── build_files/
│   ├── shared/                  # Orchestrator + helpers (build.sh,
│   │                              build-mx.sh, copr-helpers.sh,
│   │                              clean-stage.sh, validate-repos.sh)
│   ├── mx/                      # Numbered domain scripts (added in later commits)
│   └── tests/                   # 10-tests-mx.sh (smoke)
├── system_files/                # Rsync'd into / by build.sh (empty at scaffold)
├── .github/workflows/
│   ├── build-stable.yml
│   ├── build-testing.yml
│   ├── reusable-build.yml
│   └── watch-upstream.yml
├── cosign.{key,pub}             # .key gitignored
├── CLAUDE.md                    # Auto-loaded project guide
└── .claude/                     # Project Claude Code config
    ├── settings.json
    ├── commands/preflight.md
    └── docs/                    # This folder
```

## CI matrix

`.github/workflows/reusable-build.yml` is called by both `build-stable.yml` and
`build-testing.yml`. Each parent workflow passes a different `stream_name`
("stable" or "testing"), and reusable-build resolves the upstream tag accordingly.

The matrix is 3 jobs: `bazzite`, `bazzite-nvidia`, `bazzite-nvidia-open`. So
each push triggers **6 jobs total** (3 × 2 streams).

`concurrency.cancel-in-progress: true` means a new push to `main` cancels any
in-flight runs for the same workflow + ref + stream — only the latest commit's
runs survive.

## Repo isolation invariant

Every third-party repository file (added in later commits) ships to the image
with `enabled=0`. `validate-repos.sh` enforces this for an explicit list of
tracked filenames + globs (`_copr:*`, `rpmfusion-*`).


## Cockpit pattern (intentionally NOT overridden)

Bazzite ships Cockpit as a **podman quadlet** at
`/usr/share/containers/systemd/cockpit-container.container`:

```
[Container]
Image=quay.io/cockpit/ws:latest
Volume=/:/host
PodmanArgs=--privileged --pid=host --cgroups=split
```

systemd's `podman-systemd-generator` reads this at boot and
creates `cockpit-container.service` dynamically in
`/run/systemd/system/`. The `cockpit.service` stub at
`/usr/lib/systemd/system/cockpit.service` (custom-injected by
Bazzite, not owned by any RPM) `Requires=cockpit-container
.service`.

`ujust cockpit enable` toggles the stub → starts the container
→ user gets a full Cockpit UI at https://localhost:9090 with all
standard modules bundled in `quay.io/cockpit/ws:latest` and
auto-updates via `Label=io.containers.autoupdate=registry`.

bazzite-mx **deliberately does NOT add host-side `cockpit-machines`
or `cockpit-ostree` RPMs**. The container already serves all
standard modules; layering would duplicate. This is one of the
canonical examples of "skip when upstream handles it well" — see
`workflow.md` § When to skip a phase.
