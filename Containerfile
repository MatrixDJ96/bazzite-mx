# bazzite-mx: one recipe for the three flavours, BASE_IMAGE the only
# difference. CI and the local pre-flight pass it resolved to a digest
# (.github/scripts/resolve-base.sh).
ARG BASE_IMAGE=ghcr.io/ublue-os/bazzite:stable
ARG IMAGE_NAME=bazzite-mx
ARG IMAGE_VENDOR=matrixdj96
# The release tag, empty for a sandbox or pre-flight build: 10-image-info.sh
# turns an empty one into "<base version>.dev".
ARG VERSION=

FROM scratch AS ctx
COPY build_files /build_files
COPY system_files /system_files
COPY cosign.pub /cosign.pub

# The base image is the builder: it ships kernel-devel for its own kernel and
# the toolchain, so no akmods carrier stage. The self-test proves the module
# assertions refuse bad input before the real build runs.
FROM ${BASE_IMAGE} AS kmod-builder
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build_files/kmods/build-kmods.sh --self-test \
    && /ctx/build_files/kmods/build-kmods.sh

FROM ${BASE_IMAGE}
ARG IMAGE_NAME
ARG IMAGE_VENDOR
ARG VERSION

# The staged modules are bound at /kmods, a root-level mount point buildah
# removes after the RUN (like /ctx). Not under /tmp, /var or /run: clean-stage
# sweeps those with find -delete, which fails on a read-only bind mount
# (measured 2026-09-02).
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=kmod-builder,source=/out,target=/kmods \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
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

RUN --mount=type=tmpfs,target=/run \
    --network=none \
    bootc container lint --fatal-warnings --no-truncate
