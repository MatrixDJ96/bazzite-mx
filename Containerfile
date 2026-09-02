# bazzite-mx: one recipe for the three flavours, which differ in the build
# arg BASE_IMAGE, mapped from the flavour name by
# .github/scripts/resolve-base.sh, the base resolved to a digest. Two stages,
# in the order below: ctx holds the tree and is bound at /ctx, never copied
# into the image; image runs the build scripts, their smoke tests and bootc's
# lint (docs/architecture.md § Build flow).

ARG BASE_IMAGE=ghcr.io/ublue-os/bazzite:stable

# --- ctx: the tree the other stages mount -------------------------------------

FROM scratch AS ctx
COPY build_files /build_files

# --- image: build, test, lint -------------------------------------------------

FROM ${BASE_IMAGE} AS image

# /run is a tmpfs because buildah binds the host's resolv.conf under it and
# the path would otherwise stay in the image (docs/gotchas.md § A networked
# RUN leaves `/run/systemd/resolve/stub-resolv.conf` in the image).
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/run \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build_files/build.sh

# Tests read the image and must not write to it: dnf5 alone would leave
# /var/log/dnf5.log behind and trip bootc lint's var-log check, so /var/log
# and /var/cache are tmpfs here too.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=tmpfs,dst=/run \
    --mount=type=tmpfs,dst=/tmp \
    --mount=type=tmpfs,dst=/var/log \
    --mount=type=tmpfs,dst=/var/cache \
    --network=none \
    /ctx/build_files/tests/run.sh

# The last gate, offline (docs/architecture.md § Gates, in order).
RUN --mount=type=tmpfs,target=/run \
    --network=none \
    bootc container lint --fatal-warnings --no-truncate
