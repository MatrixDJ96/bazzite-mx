# Bazzite MX

A single-maintainer, **curated spin of [Bazzite](https://github.com/ublue-os/bazzite)** — a KDE
Plasma, container-first **dev & sysadmin workstation**, shipped as a signed
[bootc](https://github.com/containers/bootc) atomic image you boot into and stop thinking
about.

> **It's a build recipe, not an app.** Bazzite MX takes upstream Bazzite, layers a curated set
> of fixes and tools on top, and publishes the result as signed bootc OS images on GHCR. You
> don't clone it to run it — you **rebase your machine onto the image it produces**.

Landing page: <https://matrixdj96.github.io/bazzite-mx/> · per-build digests, pinned tags and
component versions: [Releases](https://github.com/MatrixDJ96/bazzite-mx/releases).

Built for one person's hardware and taste, in the open so every choice is auditable. Three
principles drive all of them:

- **Adds, never imposes.** Bazzite does the heavy lifting; each addition only smooths a rough
  edge or fills a real gap — never fonts, themes, or formatters. See
  [what it changes over `bazzite-dx`](docs/divergences.md).
- **Atomic-correct by construction.** Everything is baked and verified at build time; nothing
  leans on fragile first-boot mutations of a read-only `/usr`.
- **Built on giants.** Bazzite is the foundation — without it this wouldn't exist. The sharpest
  ideas are borrowed from [Aurora](https://getaurora.dev),
  [Bazzite-DX](https://github.com/ublue-os/bazzite-dx), and
  [AmyOS](https://github.com/astrovm/amyos).

## The images

Three variants, identical except for the Bazzite base they layer on and the kernel that base
ships — pick the one for your GPU:

| Image | Base | For |
|---|---|---|
| `ghcr.io/matrixdj96/bazzite-mx` | `bazzite` | non-NVIDIA hardware |
| `ghcr.io/matrixdj96/bazzite-mx-nvidia` | `bazzite-nvidia` | NVIDIA proprietary driver |
| `ghcr.io/matrixdj96/bazzite-mx-nvidia-open` | `bazzite-nvidia-open` | NVIDIA open kernel modules |

The kernel follows the base: `bazzite-nvidia` tracks Bazzite's LTS kernel for the proprietary
driver (`6.18.44-ogc1.1` today) while the other two ride the current one (`7.2.1-ogc3.1`;
read from the `ostree.linux` label, 2026-09-01). Every package the three images add is the
same.

Each ships on two rolling streams — `:stable` and `:testing` — plus dated tags for pinning;
`:latest` aliases stable. A watcher rebuilds within an hour of any upstream Bazzite release,
so the image never drifts far from its base. The full tag set of every package:

| Tag | Moves? | What it is |
|---|---|---|
| `:44.<build date>`, `:testing-44.<build date>` | never re-pointed | one build, one GitHub Release of the same name (the release title carries the upstream tag it was built from); `.1`, `.2`, … on same-day rebuilds |
| `:stable`, `:testing`, `:latest` | every build | the newest build of the stream (`latest` = `stable`) |
| `:stable-44`, `:testing-44` | every build | same, scoped to a Fedora major |
| `:staging-stable`, `:staging-testing` | every build | CI hand-off between the build matrix and the promotion gate — not for consumers |
| `:sha256-<digest>.sig` | — | the cosign signature of that digest |

Pin by digest for anything that must not change under you (the release notes list the three
digests of every build); the dated tags are a convention the CI keeps, not a registry
guarantee.

## Trying it

Bazzite MX targets its maintainer's machine, but it's a standard signed bootc image — rebase at
your own risk, picking the variant for your GPU:

```bash
sudo bootc switch ghcr.io/matrixdj96/bazzite-mx:stable
systemctl reboot
```

## What you get on top of Bazzite

**A genuine dual-runtime dev box.** Docker CE and its full plugin set run alongside Bazzite's
Podman — both sockets enabled — and a complete `libvirt` / `qemu` / `virt-manager` stack works
on first boot, with `swtpm` for TPM 2.0 and KVM module options tuned so Windows 11 guests just
boot. No `ujust setup-virtualization` dance.

**Workstation tools, done the atomic way.** VSCode with its self-updater disabled so it stops
fighting a read-only `/usr`; GitKraken and keyring-backed git auth; a deep tracing kit
(`bcc-tools`, `bpftrace`, `bpftop`, `sysprof`, `iotop-c`, and more); Firefox from Mozilla's own
RPM, so native messaging and the system keyring work out of the box; and `gparted`, restoring a
GUI partition tool to the image.

**A second NTFS driver, for the dual-boot half of the machine.** Linux 7.1 merged NTFSPLUS, a
from-scratch in-kernel NTFS read/write driver with a real fsck, but the Bazzite kernel builds
it off. Bazzite MX compiles it as an out-of-tree module and drops the generic `mount.ntfs`
helper that hands every `ntfs` mount to the FUSE ntfs-3g, so asking for the type `ntfs` reaches
the kernel driver — from `/etc/fstab`, from a systemd `.mount` unit, from `mount -t auto`, and
from udisks when you plug a disk in. `ntfs3` keeps serving `ntfs3` entries and
`mount -t ntfs-3g` still reaches FUSE, so either older driver is one mount type away.

**Extras that stay opt-in.** 1Password, Sunshine game-streaming, and full MSI-laptop EC control
each ship as a `ujust` recipe you enable only if you want it — the base image stays lean for
everyone who doesn't. MSI is the standout: stock Bazzite ships an in-tree driver that *rejects*
recent MSI EC firmware, so fan and curve control simply don't work. Bazzite MX bakes the
current upstream `msi-ec` + `acpi_ec` modules into the image, and `ujust setup-msi enable`
layers the MControlCenter GUI to drive them — you're in business.
([the full story](docs/divergences.md))

The itemised list, with provenance and rationale for every choice, lives in
[docs/divergences.md](docs/divergences.md).

## How it's built and shipped

The pipeline is deliberately boring and reproducible: an hourly watcher notices a new upstream
Bazzite release → a gate validates the `ujust` recipes → a matrix builds all three variants →
each image is signed by digest with cosign → a GitHub Release is cut. Push to `main` runs the
same path; the `develop` branch builds without pushing, as a fast CI sandbox.

Build a single variant locally before pushing — the maintainer's pre-flight, and the ONE
recipe every other reference points at (`.claude/commands/preflight.md`, `docs/workflow.md`).
It passes the same ten build-args CI does, so the labels and `image-info.json` of the local
image match a CI build instead of shipping empty:

```bash
BASE_TAG=$(skopeo inspect --retry-times 3 --no-tags docker://ghcr.io/ublue-os/bazzite:stable \
    | jq -r '.Labels["org.opencontainers.image.version"]')
UPSTREAM_DIGEST=$(skopeo inspect --retry-times 3 --no-tags "docker://ghcr.io/ublue-os/bazzite:${BASE_TAG}" \
    | jq -r .Digest)
# Kernel NVRA + the akmods flavour that carries it, resolved from the registry
# exactly as CI does (flavours differ per image: see docs/gotchas.md #32).
COORDS=/tmp/bazzite-mx-kernel-coords.env && : > "${COORDS}"
GITHUB_OUTPUT=${COORDS} ./.github/scripts/resolve-kernel-coords.sh bazzite "${BASE_TAG}"
source "${COORDS}"
podman build --file Containerfile \
  --build-arg BASE_IMAGE=bazzite \
  --build-arg BASE_TAG="${BASE_TAG}" \
  --build-arg IMAGE_NAME=bazzite-mx \
  --build-arg IMAGE_VENDOR=matrixdj96 \
  --build-arg VERSION="${BASE_TAG}" \
  --build-arg UPSTREAM_TAG="${BASE_TAG}" \
  --build-arg UPSTREAM_DIGEST="${UPSTREAM_DIGEST}" \
  --build-arg KERNEL_VERSION="${kernel_version}" \
  --build-arg KERNEL_FLAVOR="${kernel_flavor}" \
  --build-arg FEDORA_VERSION="${fedora_version}" \
  --tag localhost/bazzite-mx:preflight . 2>&1 | tee /tmp/bazzite-mx-preflight.log
BUILD_EXIT=${PIPESTATUS[0]}; echo "BUILD_EXIT=${BUILD_EXIT}"
# Rebuilding after editing build_files/? Bump VERSION (e.g. "${BASE_TAG}-verify1", once per
# retry): the build scripts are bind-mounted, so their content never invalidates the layer
# cache and an unchanged VERSION replays the old layers in seconds (docs/gotchas.md #36).
```

Budget: ~5 min with the base image and the akmods carrier already pulled, ~25 min cold (the
kmod stage rebuilds too); peak disk ~35 GB (base 11.8 GB + build layers + the committed
image). Clean up only what the pre-flight made — a global `podman image prune` also takes any
other dangling image on the machine:

```bash
podman rmi localhost/bazzite-mx:preflight
podman image prune -f --filter label=org.opencontainers.image.title=bazzite-mx
```

## Verifying a signed image

Every published image is signed by digest with cosign. Verify one against the public key
straight from the repository — no clone needed (the key is [`cosign.pub`](cosign.pub) at the
repo root):

```bash
cosign verify --key https://raw.githubusercontent.com/MatrixDJ96/bazzite-mx/main/cosign.pub \
  ghcr.io/matrixdj96/bazzite-mx:latest
```

The private `cosign.key` is gitignored — it lives only on the maintainer's machine and as a
GitHub repo secret.

## Under the hood

The build flow, conventions, and hard-won gotchas are documented for humans and coding agents
alike: [`AGENTS.md`](AGENTS.md) is the canonical guide, with deep dives in [`docs/`](docs/)
(architecture, conventions, workflow, gotchas).

## Credits

Built entirely on the shoulders of [Universal Blue](https://universal-blue.org) and
[Bazzite](https://bazzite.gg), with ideas borrowed from [Aurora](https://getaurora.dev),
[Bazzite-DX](https://github.com/ublue-os/bazzite-dx), and
[AmyOS](https://github.com/astrovm/amyos) — Bazzite MX only curates a layer on top of their
work.

## License

See [LICENSE](LICENSE).
