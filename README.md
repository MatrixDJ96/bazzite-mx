<h1><img src="site/logo.svg" alt="" width="48" height="48" align="absmiddle"> Bazzite-MX</h1>

[![release](https://img.shields.io/github/v/release/MatrixDJ96/bazzite-mx?label=release&color=7657ff)](https://github.com/MatrixDJ96/bazzite-mx/releases/latest)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

## About & Features

Bazzite-MX is [Bazzite](https://bazzite.gg) KDE turned into a development and virtualization
workstation, gaming included. Everything ships in a signed
[bootc](https://bootc-dev.github.io/bootc/) image that updates and rolls back with the system,
rebuilt on every new Bazzite `stable` image.

The [site](https://matrixdj96.github.io/bazzite-mx/) covers installation in detail.

- **[CLI tools](docs/divergences.md#command-line-tools):** `gh`, `glab`, `shellcheck`, `shfmt`,
  `ripgrep` and `telnet`.
- **[Development](docs/divergences.md#visual-studio-code):** VS Code, GitKraken, mise and full
  git.
- **[Containers](docs/divergences.md#docker-ce):** Docker CE and Podman, with Compose.
- **[Virtualization](docs/divergences.md#virtualization-and-quickemu):** libvirt, QEMU/KVM,
  virt-manager and quickemu.
- **[Streaming](docs/divergences.md#sunshine):** Sunshine as a native RPM, with KMS capture.
- **[Filesystems](docs/divergences.md#ntfsplus-on-every-flavour):** NTFSPLUS in place of
  ntfs-3g, and GParted.
- **[MSI laptops](docs/divergences.md#msi-laptop-kernel-modules-and-mcontrolcenter):** fan,
  battery and keyboard control with `msi-ec` and MControlCenter.

## Installation

> [!WARNING]
> Turn Secure Boot off: the NTFSPLUS and MSI modules are unsigned. With Windows drives in
> `/etc/fstab` or a Windows dual boot, read
> [NTFSPLUS](docs/divergences.md#ntfsplus-on-every-flavour) first.

From Bazzite KDE (not GNOME), pick the `<image>` for your GPU: `bazzite-mx` (AMD, Intel),
`bazzite-mx-nvidia-open` (GTX 16, RTX) or `bazzite-mx-nvidia` (GTX 750 to GTX 10).

**1.** Rebase to it and reboot:

```bash
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/matrixdj96/<image>:stable
```

**2.** Switch to the signed image and reboot:

```bash
ujust migrate stable
```

**3.** Check that everything is in place:

```bash
ujust verify-host
```

## Recipes

| Recipe                             | Description                                                    |
| ---------------------------------- | -------------------------------------------------------------- |
| `ujust setup-dev install`          | Installs the default mise runtimes (Node, Python, Java, .NET). |
| `ujust install-jetbrains-toolbox`  | Installs the latest JetBrains Toolbox release.                 |
| `ujust setup-virtualization kvmfr` | Sets up the kvmfr module for Looking Glass.                    |
| `ujust setup-sunshine enable`      | Starts Sunshine streaming automatically at login.              |
| `ujust setup-msi enable`           | Loads the MSI EC modules and installs MControlCenter.          |
| `ujust setup-panels`               | Adds a custom taskbar to each secondary monitor.               |

`ujust <recipe> help` lists every option of a recipe.

## Verification

With [`cosign.pub`](cosign.pub) from this repository:

```bash
cosign verify --key cosign.pub ghcr.io/matrixdj96/<image>:stable
```

## Build Your Own

```bash
./.github/scripts/preflight-build.sh <flavour>
```

`<flavour>` is `bazzite` (the default), `bazzite-nvidia-open` or `bazzite-nvidia`; it needs
podman, skopeo and jq.

## Special Thanks

- [Bazzite](https://github.com/ublue-os/bazzite) and
  [Universal Blue](https://universal-blue.org/), the base this image builds on.
- [bazzite-dx](https://github.com/ublue-os/bazzite-dx) and
  [Aurora](https://github.com/ublue-os/aurora), for their developer setups.

## License

[Apache-2.0](LICENSE)
