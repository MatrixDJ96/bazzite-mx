# bazzite-mx: one recipe for the three flavours, which differ in the two
# build args BASE_IMAGE and IMAGE_NAME, both mapped from the flavour name by
# .github/scripts/resolve-base.sh, the base resolved to a digest
# (docs/architecture.md § Build flow).

ARG BASE_IMAGE=ghcr.io/ublue-os/bazzite:stable
ARG IMAGE_NAME=bazzite-mx
ARG IMAGE_VENDOR=matrixdj96

# The version the image calls itself, empty unless the build passes one:
# 10-image-info.sh then applies the "<base version>.dev" rule.
ARG VERSION=

# --- ctx: the tree the other stages mount -------------------------------------

FROM scratch AS ctx
COPY build_files /build_files
COPY system_files /system_files
COPY cosign.pub /cosign.pub

# --- kmod-builder: the out-of-tree modules ------------------------------------

# The base image is the builder: it ships kernel-devel for its own kernel and
# the toolchain, so no akmods carrier stage.
FROM ${BASE_IMAGE} AS kmod-builder
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build_files/kmods/build-kmods.sh --self-test \
    && /ctx/build_files/kmods/build-kmods.sh

# --- image: build, test, lint -------------------------------------------------

FROM ${BASE_IMAGE} AS image
ARG IMAGE_NAME
ARG IMAGE_VENDOR
ARG VERSION

# /kmods is a root-level mount point, never under /var: clean-stage empties
# /var, which fails on a read-only bind mount. /run is a tmpfs because buildah
# binds the host's resolv.conf under it and the path would otherwise stay in
# the image (docs/gotchas.md § A networked RUN leaves
# `/run/systemd/resolve/stub-resolv.conf` in the image).
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=kmod-builder,source=/out,target=/kmods \
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
    rpm -V --nomtime python3-setuptools \
    && bootc container lint --fatal-warnings --no-truncate
