# bazzite-mx

Personal Bazzite-based bootc atomic distribution. KDE Plasma + container-first dev/sysadmin workstation.

## What is bazzite-mx?

bazzite-mx is a personal fork of [Universal Blue Bazzite](https://github.com/ublue-os/bazzite). It is a **single-maintainer project**, not a community distribution.

This repository builds and publishes three GHCR images that differ only in `BASE_IMAGE`:

| Image | Base | Use case |
|-------|------|----------|
| `ghcr.io/matrixdj96/bazzite-mx` | `ghcr.io/ublue-os/bazzite` | non-NVIDIA hardware |
| `ghcr.io/matrixdj96/bazzite-mx-nvidia` | `ghcr.io/ublue-os/bazzite-nvidia` | NVIDIA proprietary driver |
| `ghcr.io/matrixdj96/bazzite-mx-nvidia-open` | `ghcr.io/ublue-os/bazzite-nvidia-open` | NVIDIA open kernel modules |

Each variant is published with two stream tags: `:stable` and `:testing`.

## What's added on top of Bazzite

| Domain | What | Why |
|---|---|---|
| **Container runtime** | Docker CE + extras (compose, machine, tui, bootc) + sockets | full Docker workflow alongside Bazzite's existing Podman; isolated upstream Docker repo (`docker-ce.repo` vendored, `enabled=0`) |
| **Virtualization** | libvirt, qemu, virt-manager, swtpm, waypipe + `libvirtd.service` enabled at build + KVM kargs (`kvm.ignore_msrs=1`, `kvm.report_ignored_msrs=0`) shipped via `bootc/kargs.d` + flatpak virt-manager masked | Windows 11 VM compat (TPM 2.0 via swtpm) + remote-display Wayland forwarding; the stack is fully working on first boot without `ujust setup-virtualization` (which is also overridden to remove an upstream gate that silently no-ops on RPM-installed virt-manager) |
| **IDE / Dev** | VSCode (`update.mode=none`) + GitKraken + `git-credential-libsecret` | atomic-correct settings (auto-update fights `/usr` read-only); keyring-backed git auth; minimalism (no opinionated font/theme/formatter overrides) |
| **Dev / Sysadmin CLI** | `bcc-tools` + `bpftrace` + `bpftop` + `sysprof` + `iotop-c` + `nicstat` + `numactl` + `trace-cmd` + `flatpak-builder` + `gh` (upstream vendored repo) + `cosign` (already in Bazzite base) | observability + container build + GitHub workflow |
| **Web / browsers** | Firefox via Mozilla RPM repo (replaces Flatpak Firefox) + Bazzite's flatpak default-install adjusted to skip Firefox | RPM Firefox supports system fonts, system policies, native messaging; Flatpak doesn't |

## Build

```bash
podman build --file Containerfile \
  --build-arg BASE_IMAGE=bazzite \
  --build-arg BASE_TAG=$(skopeo inspect --no-tags \
      docker://ghcr.io/ublue-os/bazzite:stable \
      | jq -r '.Labels["org.opencontainers.image.version"]') \
  --build-arg IMAGE_NAME=bazzite-mx \
  --tag localhost/bazzite-mx:preflight .
```

CI runs on every push to `main` and re-runs hourly via the upstream-watcher workflow whenever upstream Bazzite publishes a new release.

## Image signing

Each pushed image is signed by digest with cosign using `SIGNING_SECRET`. Verify a deployed image:

```bash
cosign verify --key cosign.pub ghcr.io/matrixdj96/bazzite-mx:latest
```

The local `cosign.key` is gitignored — it lives only on the maintainer's machine and in the GitHub repo secret.

## License

See [LICENSE](LICENSE).
