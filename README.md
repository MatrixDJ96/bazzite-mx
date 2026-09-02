# Bazzite-MX

A personal [bootc](https://bootc-dev.github.io/bootc/) image on top of
[Bazzite](https://bazzite.gg) (KDE desktop, `stable` stream): the system layer only, with
applications left to Flatpak and mutable userspace to distrobox.

Three flavours, one recipe; only the base image and the image name differ:

| Image                    | Base                                          | For                         |
| ------------------------ | --------------------------------------------- | --------------------------- |
| `bazzite-mx`             | `ghcr.io/ublue-os/bazzite:stable`             | AMD / Intel graphics        |
| `bazzite-mx-nvidia-open` | `ghcr.io/ublue-os/bazzite-nvidia-open:stable` | NVIDIA Turing and newer GPU |
| `bazzite-mx-nvidia`      | `ghcr.io/ublue-os/bazzite-nvidia:stable`      | NVIDIA Maxwell to Volta GPU |

What the image changes over Bazzite, and why, is [`docs/divergences.md`](docs/divergences.md).

## What the image adds

- Signing trust for `ghcr.io/matrixdj96/*`: a host pulls only what this repository signed.

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
- [`docs/conventions.md`](docs/conventions.md): the rules for scripts, tests and CI.
- [`docs/divergences.md`](docs/divergences.md): what changes over Bazzite, and why.
- [`docs/gotchas.md`](docs/gotchas.md): surprises found here, each with how it was found.
- [`docs/workflow.md`](docs/workflow.md): branches and the sandbox.

## License

Apache-2.0, see [`LICENSE`](LICENSE).
