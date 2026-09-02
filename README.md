# Bazzite-MX

A personal [bootc](https://bootc-dev.github.io/bootc/) image on top of
[Bazzite](https://bazzite.gg) (KDE desktop, `stable` stream): the system layer only, with
applications left to Flatpak and mutable userspace to distrobox.

Three flavours, one recipe; only the base image differs:

| Image                    | Base                                          | For                         |
| ------------------------ | --------------------------------------------- | --------------------------- |
| `bazzite-mx`             | `ghcr.io/ublue-os/bazzite:stable`             | AMD / Intel graphics        |
| `bazzite-mx-nvidia-open` | `ghcr.io/ublue-os/bazzite-nvidia-open:stable` | NVIDIA Turing and newer GPU |
| `bazzite-mx-nvidia`      | `ghcr.io/ublue-os/bazzite-nvidia:stable`      | NVIDIA Maxwell to Volta GPU |

What the image changes over Bazzite, and why, is [`docs/divergences.md`](docs/divergences.md).

## Build it yourself

```bash
# resolve-base.sh pins the base to its current digest, the way CI does
eval "$(./.github/scripts/resolve-base.sh bazzite)"   # or bazzite-nvidia-open, bazzite-nvidia
podman build --build-arg BASE_IMAGE="$base_image" --tag localhost/bazzite-mx .
```

## Documentation

- [`docs/conventions.md`](docs/conventions.md): the rules for scripts and CI.
- [`docs/divergences.md`](docs/divergences.md): what changes over Bazzite, and why.
- [`docs/workflow.md`](docs/workflow.md): branches and the sandbox.

## License

Apache-2.0, see [`LICENSE`](LICENSE).
