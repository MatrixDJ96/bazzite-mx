# Bazzite-MX

A personal [bootc](https://bootc-dev.github.io/bootc/) image on top of
[Bazzite](https://bazzite.gg) (KDE desktop, `stable` stream): the system layer only, with
applications left to Flatpak and mutable userspace to distrobox.

Three flavours, one recipe; only the base image and the image name differ:

| Image                                       | Base                                          | For                         |
| ------------------------------------------- | --------------------------------------------- | --------------------------- |
| `ghcr.io/matrixdj96/bazzite-mx`             | `ghcr.io/ublue-os/bazzite:stable`             | AMD / Intel graphics        |
| `ghcr.io/matrixdj96/bazzite-mx-nvidia-open` | `ghcr.io/ublue-os/bazzite-nvidia-open:stable` | NVIDIA Turing and newer GPU |
| `ghcr.io/matrixdj96/bazzite-mx-nvidia`      | `ghcr.io/ublue-os/bazzite-nvidia:stable`      | NVIDIA Maxwell to Volta GPU |

`:stable` is the tag a host follows, and it moves onto a release only through the gate that
verified its signature. What the image changes over Bazzite, and why, is
[`docs/divergences.md`](docs/divergences.md).

## What the image adds

- Hardware: `msi-ec` and `acpi_ec` for MSI laptops, plus MControlCenter (`ujust setup-msi`).
- Containers and VMs: Docker CE, libvirt, QEMU/KVM, swtpm (`ujust setup-virtualization`).
- Development: VS Code, GitKraken, `gh`, `glab`, ShellCheck, shfmt, mise (`ujust setup-dev`).
- The JetBrains Toolbox installer (`ujust install-jetbrains-toolbox`).
- Desktop: Firefox, gparted and 1Password as RPMs; Firefox and virt-manager Flatpaks denied.
- Sunshine with the KMS capabilities its RPM carries (`ujust setup-sunshine`).
- KDE defaults: clock seconds, a panel per screen, Ctrl+C to copy in Konsole.
- Signing trust for `ghcr.io/matrixdj96/*`: a host pulls only what this repository signed.
- Host recipes `ujust migrate`, `ujust verify-host` and `ujust setup-ntfsplus` (an opt-in).

## Switch a Bazzite host

A stock Bazzite trusts no key for `ghcr.io/matrixdj96`, so the first rebase goes through the
unsigned transport. The recipe moves the host onto the signed one afterwards.

A host with `ntfs` rows in `fstab` reads [`docs/migration.md`](docs/migration.md) § The first
rebase goes through the unsigned transport before running it.

```bash
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/matrixdj96/bazzite-mx:stable
systemctl reboot
ujust migrate apply
systemctl reboot
ujust verify-host
```

On an NVIDIA machine, name `bazzite-mx-nvidia-open` (Turing and newer) or `bazzite-mx-nvidia`
(Maxwell, Pascal and Volta) in the first line; an older GPU stays on `bazzite-mx`.

Step 2 of `migrate apply` (backups, pin, timer stop) runs without asking; every other step that
changes the host asks first. The steps and the checks are in
[`docs/migration.md`](docs/migration.md).

## Verify an image

```bash
cosign verify --key https://raw.githubusercontent.com/MatrixDJ96/bazzite-mx/main/cosign.pub \
  ghcr.io/matrixdj96/bazzite-mx:stable
gh attestation verify oci://ghcr.io/matrixdj96/bazzite-mx:stable --repo MatrixDJ96/bazzite-mx
```

`gh attestation verify` wants a GitHub login first (`gh auth login`, or `GH_TOKEN` in the
environment), public repository or not.

The key is [`cosign.pub`](cosign.pub), the one the image itself trusts.

## Build it yourself

```bash
# resolve-base.sh pins the base to its current digest, the way CI does
eval "$(./.github/scripts/resolve-base.sh bazzite)"   # or bazzite-nvidia-open, bazzite-nvidia
podman build --build-arg BASE_IMAGE="$base_image" --build-arg IMAGE_NAME="$image_name" \
    --tag localhost/bazzite-mx .
```

## Documentation

- [`AGENTS.md`](AGENTS.md): the project guide for anyone working on the repo.
- [`docs/architecture.md`](docs/architecture.md): build flow, layout, build state, the gates.
- [`docs/conventions.md`](docs/conventions.md): the rules for scripts, recipes, tests and CI.
- [`docs/divergences.md`](docs/divergences.md): what changes over Bazzite, and why.
- [`docs/gotchas.md`](docs/gotchas.md): surprises found here, each with how it was found.
- [`docs/migration.md`](docs/migration.md): bringing a host onto the image, re-checking one.
- [`docs/workflow.md`](docs/workflow.md): branches, the release run, promotions.

## License

Apache-2.0, see [`LICENSE`](LICENSE).
