# Architecture

## What `bazzite-mx` is

A personal **bootc atomic distribution** built on top of upstream Bazzite, adopting the
Aurora-DX build style (numbered scripts per domain, isolated repos, blocking smoke tests,
targeted cleanup) with bazzite-dx's script auto-discovery (the `find … | sort` enumeration in
`build-mx.sh`; Aurora chains its scripts by hand in `Containerfile.in`).

## Single-flavour design

bazzite-mx is single-flavour **by definition**: no `IMAGE_TIER` toggle, no `-dx` suffix
variant, no separate "lite" image — every build step in `build_files/mx/` runs unconditionally
on every image. The three GHCR images differ **only** in `BASE_IMAGE`:

| Image | BASE_IMAGE | Use case |
|---|---|---|
| `bazzite-mx` | `bazzite` | non-NVIDIA hardware |
| `bazzite-mx-nvidia` | `bazzite-nvidia` | NVIDIA proprietary driver |
| `bazzite-mx-nvidia-open` | `bazzite-nvidia-open` | NVIDIA open kernel modules |

## Containerfile flow

The Containerfile has four stages — `ctx`, `akmods-rpms`, `kmod-builder` (its own `RUN`
compiles the out-of-tree kernel modules, see below) and the final image. The final stage has 3
`RUN` steps:

1. **`/ctx/build_files/shared/build.sh`** — orchestrator that (a) rsyncs `system_files/` into
   `/`, (b) calls `build-mx.sh`, (c) runs `clean-stage.sh`, (d) runs `validate-repos.sh`, (e)
   rewrites the rpmdb the build wrote onto a fresh inode and relinks the rpm-ostree base-db
   to it (build.sh steps 4 and 5). Mounts a build-context
   bind, plus `/var/cache` and `/var/log` as caches and `/tmp` as tmpfs.
2. **`/ctx/build_files/tests/10-tests-mx.sh`** — smoke test (rpm-q + systemctl is-enabled +
   file-existence assertions). The `/ctx` bind-mount is preserved so the test can read the
   build context if needed.
3. **`bootc container lint --fatal-warnings --no-truncate`** — a new warning (runtime-dir
   residue, `/boot` content) fails the build instead of scrolling by.

## Build orchestration order

Inside `build.sh`:

```
rsync system_files/ → /
build-mx.sh
  ├─ writes /etc/sysctl.d/90-bazzite-mx-forwarding.conf
  ├─ writes /etc/modules-load.d/90-bazzite-mx-nat.conf
  └─ enumerate build_files/mx/[0-9]*-*.sh in version order
       (mapfile -t < <(find … | sort -V))
       │
       └─ 18 numbered domain scripts (00-image-info.sh … 72-ntfsplus.sh)
clean-stage.sh
  ├─ restore pristine /etc/dnf/dnf.conf (from /tmp/dnf.conf.orig)
  ├─ rm -rf /usr/lib/sysimage/libdnf5/*
  ├─ mask + remove flatpak-add-fedora-repos.service
  ├─ sed enabled=1→0 on terra-mesa.repo (the base leaves it file-level enabled; gotcha #2)
  ├─ find /var/* -maxdepth 0 -type d ! -name cache ! -name log -exec rm -fr {} \;
  ├─ rm -rf /tmp/* + mkdir /var/tmp + chmod 1777 /var/tmp
  └─ sweep /run (keeps the container plumbing) + find /boot -mindepth 1 -delete (bootc lint runs --fatal-warnings)
validate-repos.sh
  └─ hard-fails if any third-party-repos.list entry (or _copr_* / rpmfusion-*) is enabled=1
step 4: fresh-inode rewrite (VACUUM INTO + os.replace, sidecars dropped)
  └─ /usr/share/rpm/rpmdb.sqlite
step 5: relink /usr/lib/sysimage/rpm-ostree-base-db/rpmdb.sqlite (hardlink, sidecars dropped)
```

Step 4 runs last because every dnf5 transaction of the stage must already have written its
pages. It is the sqlite half of the torn-writeback guard; the text half is
`rewrite_fresh_inode` from `shared/writeback-helpers.sh`, called by every script that writes a
base-image file in place. See [`conventions.md`](conventions.md) § Writing base-image files.

### Decade map (`build_files/mx/`)

Each decade owns one domain; `build-mx.sh` runs the scripts in version order:

| Decade | Domain | Scripts |
|---|---|---|
| 00 | Identity / branding | `00-image-info.sh` |
| 10 | Container runtime | `10-container-runtime.sh` |
| 20 | Virtualization | `20-virtualization.sh`, `21-virt-manager-flatpak-exclude.sh` |
| 30 | IDE + git tools | `30-ide.sh`, `35-git-tools.sh` |
| 40 | Dev CLI (rpms + pinned binaries) | `40-dev-cli-rpms.sh`, `41-dev-cli-pinned.sh` |
| 50 | Bazzite extras + justfile reconcile | `50-bazzite-extras.sh`, `55-justfile-reconcile.sh` |
| 60 | Desktop apps + repo/key provisioning for opt-in layering | `60-desktop-apps.sh`, `61-firefox-rpm.sh`, `62-firefox-flatpak-exclude.sh`, `64-1password-key.sh`, `65-sunshine.sh` |
| 70 | Out-of-tree kmods install | `70-msi-ec.sh`, `71-acpi-ec.sh`, `72-ntfsplus.sh` |

`55-justfile-reconcile.sh` has two responsibilities: (1) **surgical override removal** — for
each recipe bazzite-mx replaces (`setup-sunshine`, `setup-virtualization`,
`install-jetbrains-toolbox`), it strips the same-named recipe from its upstream `.just` file
(`just` rejects duplicate recipe names across imports), hard-failing the build if a named
recipe is absent (upstream-drift guard); (2) **import registration** — it idempotently appends
`import` directives for both `95-bazzite-mx.just` (net-new recipes) and
`96-bazzite-mx-overrides.just` (the override bodies) to Bazzite's master
`/usr/share/ublue-os/justfile`; (3) **fresh-inode rewrite** — both edits above land in place on
base-image files, so the script closes by calling `rewrite_fresh_inode` on the master and the
three stripped upstream files.

### `build_files/kmods/` — out-of-tree kernel modules

`build_files/kmods/` is built in a dedicated `kmod-builder` Containerfile stage, NOT by
`build-mx.sh` (whose `[0-9]*-*.sh` glob only runs `build_files/mx/`). It compiles out-of-tree
kernel modules (`msi-ec`, `acpi_ec`, `ntfsplus`) against `kernel-devel` from the
`akmods:<flavour>-<fedora>-<kver>` carrier and stages the `.ko` files for the final stage,
which installs them into `updates/` and runs `depmod`.

The three coordinates of that carrier tag come from `.github/scripts/resolve-kernel-coords.sh`,
which reads the base image's `ostree.linux` label and asks the registry which akmods flavours
carry that exact kernel NVRA. The flavour is per-image and upstream changes it: a flavour whose
driver lags a mainline kernel bump rides the LTS branch (`ogc-lts`) while its siblings ride
`ogc`. CI, `/preflight` and the README recipe all call that one resolver.

Each module is one directory holding a single `source.env`, sourced by the loop in
`build-kmods.sh`: `URL`, a pinned `COMMIT`, `KO_NAME`, `KO_DEST`, plus two optional keys —
`KO_BUILD_PATH` (the built object's path relative to the clone root, when the Makefile emits it
in a subdirectory: `acpi_ec`) and `KO_BUILD_ARGS` (extra `make` variables, needed when the
module's kbuild fragment is gated on a kernel config symbol the target kernel leaves unset:
`ntfsplus`). Adding a module is one new directory plus one entry in `KMODS=()` and one numbered
install script in the 70 decade.

## Repository layout

```
bazzite-mx/
├── Containerfile                # 4-stage: ctx + akmods-rpms + kmod-builder + final
├── build_files/
│   ├── shared/                  # Orchestrator + helpers (build.sh,
│   │                              build-mx.sh, copr-helpers.sh,
│   │                              writeback-helpers.sh, clean-stage.sh,
│   │                              validate-repos.sh)
│   ├── mx/                      # 18 numbered domain scripts (<NN>-<domain>.sh)
│   ├── kmods/                   # Out-of-tree kernel module builder (see note above)
│   └── tests/                   # 10-tests-mx.sh (smoke)
├── system_files/                # Rsync'd into / by build.sh (yum.repos.d, skel,
│                                  ujust recipes, setup hooks, sysusers.d,
│                                  bootc install/ + modprobe.d)
├── site/                        # GitHub Pages landing page (index.html + assets)
├── .github/workflows/
│   ├── build.yml
│   ├── clean.yml
│   ├── deploy-pages.yml
│   ├── generate-release.yml
│   ├── reusable-build.yml
│   ├── sign-image.yml
│   └── watch-upstream.yml
├── .github/scripts/             # Host-side helpers called by the workflows
│   ├── changelog.sh             # Release-notes generator, digests via IMAGE_DIGESTS (generate-release.yml)
│   ├── check-image-integrity.sh # Cold post-rechunk check + --self-test (reusable-build.yml)
│   ├── list-flavours.sh         # ONE owner of the flavour set (matrix plan, watcher, release, cleanup, resolver, changelog)
│   ├── promote-release-tags.sh  # Per-stream alias/release-tag promotion after the matrix gate (reusable-build.yml)
│   ├── resolve-kernel-coords.sh # akmods carrier flavour/version (reusable-build.yml)
│   ├── resolve-release-tag.sh   # Downstream tag schema (build.yml)
│   ├── resolve-upstream-tag.sh  # ONE owner of "latest upstream tag for a stream" + the 404-gated .N strip
│   └── verify-published-signatures.sh # Negative control + cosign verify of the promoted images (reusable-build.yml)
├── cosign.{key,pub}             # .key gitignored
├── AGENTS.md                    # Canonical project guide (every agent)
├── CLAUDE.md                    # Claude Code bridge → @AGENTS.md
└── docs/                        # Deep knowledge (this folder)
```

## CI matrix

`.github/workflows/build.yml` is the single entry point for both streams, the shape upstream
`Build Bazzite` uses. Its `plan` job decides the stream set — the `streams` input on a dispatch
or a `Watch Upstream` call, `both` by default — and emits `matrix_include`, a JSON array of
flavour × stream entries. `reusable-build.yml` is called **once**, with that matrix:
`stream_name` is a matrix dimension, not a workflow input, so the run shows ONE `Build matrix`
node of up to 6 jobs. The per-stream tags travel as four inputs
(`upstream_tag_{stable,testing}`, `release_tag_{stable,testing}`) and each matrix job picks its
pair in the `Select stream inputs` step.

The matrix is 3 flavours (`bazzite`, `bazzite-nvidia`, `bazzite-nvidia-open`) × 2 streams = **6
build jobs** in every context — `develop` and PR sandboxes included: base images differ per
stream too, so a stable-only sandbox is blind to testing-base drift.

Downstream of the matrix, the gate is **per stream**: `promote-{stable,testing}` each count
their own `promote-*-<stream>` manifests against `matrix_include` (never a literal 3) and abort
loudly on a shortfall; `verify-{stable,testing}` mirror them. The always-running `gate` job
turns those results into the callee outputs `stable_ok`/`testing_ok`, which the caller's
`release-*` jobs gate on instead of the callee's aggregate result — a broken testing base
(upstream's doing) must not sink the stable release, and vice versa.

`concurrency.cancel-in-progress: false` (with a literal kebab-case
`group: bazzite-mx-build-${{ github.ref_name }}`) means in-flight runs are not auto-cancelled,
and `develop` runs proceed in parallel with `main`. The callee keeps its own literal group
(`bazzite-mx-reusable-<ref>`). AGENTS.md critical convention #8 owns the full naming rationale
(why the group must never be `${{ github.workflow }}`).

## Repo isolation invariant

Every third-party repository file ships to the image with `enabled=0`. `validate-repos.sh`
enforces this for an explicit list of tracked filenames + globs (`_copr:*`, `rpmfusion-*`).

## Cockpit pattern (intentionally NOT overridden)

Bazzite ships Cockpit as a **podman quadlet** at
`/usr/share/containers/systemd/cockpit-container.container`:

```
[Container]
Image=quay.io/cockpit/ws:latest
Volume=/:/host
PodmanArgs=--privileged --pid=host --cgroups=split
```

systemd's `podman-systemd-generator` reads this at boot and creates `cockpit-container.service`
dynamically in `/run/systemd/system/`. The `cockpit.service` stub at
`/usr/lib/systemd/system/cockpit.service` (custom-injected by Bazzite, owned by no RPM)
`Requires=cockpit-container.service`.

`ujust cockpit enable` toggles the stub → starts the container → a full Cockpit UI at
https://localhost:9090 with all standard modules bundled in `quay.io/cockpit/ws:latest`,
auto-updated via `Label=io.containers.autoupdate=registry`.

bazzite-mx **deliberately does NOT add host-side `cockpit-machines` or `cockpit-ostree` RPMs**
— the container already serves all standard modules; layering would duplicate. This is a
canonical example of "skip when upstream handles it well" — see [`workflow.md`](workflow.md) §
When to skip a phase.
