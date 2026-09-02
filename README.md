# bazzite-mx

A personal [bootc](https://bootc-dev.github.io/bootc/) image on top of
[Bazzite](https://bazzite.gg) (KDE desktop, `stable` stream). The image is the system layer:
kernel modules, system services, third-party repositories, signing trust and the `ujust`
recipes that set a host up. Graphical applications stay in Flatpak, command-line tools come
from Fedora or Homebrew, mutable userspace lives in distrobox.

Two flavours, one recipe — only the base image differs:

| Image | Base | For |
|---|---|---|
| `ghcr.io/matrixdj96/bazzite-mx` | `ghcr.io/ublue-os/bazzite:stable` | AMD / Intel graphics |
| `ghcr.io/matrixdj96/bazzite-mx-nvidia-open` | `ghcr.io/ublue-os/bazzite-nvidia-open:stable` | NVIDIA, open kernel modules |

## Status

Version 2 is being rebuilt from an empty tree, one verified feature per commit. The images
above are not published from this tree yet; the previous generation is archived on the
`archive/v1` branch (tags `v1-final`, `v1-develop-final`).

## Build it yourself

```bash
eval "$(./.github/scripts/resolve-base.sh bazzite)"   # or bazzite-nvidia-open
podman build --build-arg BASE_IMAGE="$base_image" --tag localhost/bazzite-mx .
```

`resolve-base.sh` pins the base to its current digest and reads the kernel from the base's
`ostree.linux` label; CI runs the same script. The last step of the build is
`bootc container lint --fatal-warnings`: a lint warning is a failed build.

## License

Apache-2.0, see [`LICENSE`](LICENSE).
