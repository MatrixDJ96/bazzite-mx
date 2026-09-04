# bazzite-mx

A personal [bootc](https://bootc-dev.github.io/bootc/) image on top of
[Bazzite](https://bazzite.gg) (KDE desktop, `stable` stream). The image is the system layer:
kernel modules, system services, third-party repositories, signing trust and the `ujust`
recipes that set a host up. Graphical applications stay in Flatpak, command-line tools come
from Fedora or Homebrew, mutable userspace lives in distrobox. A change enters the image only
when Bazzite does not cover it, it needs the image layer, a host of the fleet uses it, and it
ships a smoke test with its source cited: every one of them is in
[`docs/divergences.md`](docs/divergences.md).

Three flavours, one recipe — only the base image differs:

| Image | Base | For |
|---|---|---|
| `ghcr.io/matrixdj96/bazzite-mx` | `ghcr.io/ublue-os/bazzite:stable` | AMD / Intel graphics |
| `ghcr.io/matrixdj96/bazzite-mx-nvidia-open` | `ghcr.io/ublue-os/bazzite-nvidia-open:stable` | NVIDIA, open kernel modules |
| `ghcr.io/matrixdj96/bazzite-mx-nvidia` | `ghcr.io/ublue-os/bazzite-nvidia:stable` | NVIDIA, closed driver |

Every release carries a dated tag, `44.<build date>` (`.N` only on a same-day rebuild), listed
on the [releases page](https://github.com/MatrixDJ96/bazzite-mx/releases) with the digest of
each image and the packages that changed. `:stable` is the tag a host follows: it moves onto a
release only through the gate that verified its signature and its attestation.

## What the image adds

- **Hardware**: the out-of-tree `msi-ec` and `acpi_ec` modules for MSI laptops, built against
  the image's kernel and enabled per host with `ujust setup-msi`.
- **Containers and VMs**: Docker CE beside Podman, both sockets enabled; libvirt with QEMU/KVM,
  virt-manager, swtpm and quickemu, `ujust setup-virtualization`.
- **Development**: Visual Studio Code, GitKraken, `gh`, `glab`, ShellCheck, shfmt, mise with
  default runtimes (`ujust setup-dev`), the JetBrains Toolbox installer, tracing and
  system-administration tools.
- **Desktop**: Firefox and gparted as RPMs, 1Password installed in the image (no layering, so
  `bootc status` stays compatible), Sunshine with `ujust setup-sunshine`, KDE defaults (clock
  with seconds, a panel per screen, Ctrl+C / Ctrl+V in Konsole).
- **Trust**: the image ships the policy and the key that verify `ghcr.io/matrixdj96/*`, so a
  migrated host pulls only what this repository signed.
- **Host recipes**: `ujust migrate` moves a host to the signed transport, to a bootc-clean
  deployment and, where `fstab` has NTFS rows, to the in-kernel `ntfs3` driver;
  `ujust verify-host` prints one line per check; `ujust setup-ntfsplus` switches a host's NTFS
  volumes to the NTFSPLUS driver the image ships (opt-in, proven on a loop image first,
  `disable` reverts).

## Switch a Bazzite host

A signed pull is verified against the policy of the deployment that runs it, and a stock
Bazzite carries no trust for `ghcr.io/matrixdj96`: the first rebase goes through the unsigned
transport, then the recipe in the image moves the host to the signed one, removes what bootc
cannot manage and rewrites NTFS entries of `fstab`. Every step asks first.

```bash
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/matrixdj96/bazzite-mx:stable
systemctl reboot
ujust migrate apply
ujust verify-host
```

Use `bazzite-mx-nvidia-open` on an NVIDIA machine (`bazzite-mx-nvidia` for the closed driver). Afterwards the host updates the Bazzite way
(`uupd`, or `bootc upgrade`) and rolls back with `rpm-ostree rollback`. The recipe, its checks
and the per-host notes are in [`docs/migration.md`](docs/migration.md).

## Verify an image

Every published image is signed by digest with the key the image itself trusts
([`cosign.pub`](cosign.pub)) and attested by the workflow run that built it:

```bash
cosign verify --key https://raw.githubusercontent.com/MatrixDJ96/bazzite-mx/main/cosign.pub \
  ghcr.io/matrixdj96/bazzite-mx:stable
gh attestation verify oci://ghcr.io/matrixdj96/bazzite-mx:stable --repo MatrixDJ96/bazzite-mx
```

The attestation check needs a registry login (`gh attestation verify` manual).

## How it is built and shipped

One `Containerfile`: a builder stage compiles the kernel modules with the base's own
`kernel-devel`, then three `RUN` steps on the base — `build_files/build.sh` runs one script per
feature in order, `build_files/tests/run.sh` runs one smoke test per script offline on the
cleaned tree, and `bootc container lint --fatal-warnings` has the last word. Every guard in the
build and in CI ships a `--self-test` that proves it fails on known-bad input.

CI never publishes from a push: `develop` and pull requests build the three flavours and probe the
image; `main` also composes the chunked image a host would pull, probes it and proves the
signing key. A release comes only from a dispatched workflow — by hand, by the weekly trigger
or by the upstream watcher — which builds, pushes `:staging`, signs by digest, attaches the
SBOM, attests, verifies everything again in a separate job and only then writes the dated tag
and the GitHub Release. The whole flow, the promotions and the retention are in
[`docs/workflow.md`](docs/workflow.md); the build flow and the layout in
[`docs/architecture.md`](docs/architecture.md).

## Build it yourself

```bash
eval "$(./.github/scripts/resolve-base.sh bazzite)"   # or bazzite-nvidia-open, bazzite-nvidia
podman build --build-arg BASE_IMAGE="$base_image" --tag localhost/bazzite-mx .
```

`resolve-base.sh` pins the base to its current digest and reads the kernel from the base's
`ostree.linux` label; CI runs the same script. The last step of the build is
`bootc container lint --fatal-warnings`: a lint warning is a failed build.

## Documentation

| File | What it holds |
|---|---|
| [`AGENTS.md`](AGENTS.md) | the project guide for anyone (or any agent) working on the repo: layout, rules, cheatsheet |
| [`docs/architecture.md`](docs/architecture.md) | build flow, every script and its role, the state of a build, the gates, the CI |
| [`docs/conventions.md`](docs/conventions.md) | bash, build scripts, recipes, hooks, tests, positive control, CI, commits |
| [`docs/divergences.md`](docs/divergences.md) | what changes over Bazzite, why, with sources and measurements |
| [`docs/gotchas.md`](docs/gotchas.md) | facts measured on this project that a reader would rediscover the hard way |
| [`docs/migration.md`](docs/migration.md) | moving a host to the image, per-host notes |
| [`docs/workflow.md`](docs/workflow.md) | branches and profiles, the release run, trigger and watcher, retention, promotions, repository settings, pins |

The previous generation of this image is archived on the `archive/v1` branch.

## License

Apache-2.0, see [`LICENSE`](LICENSE).
