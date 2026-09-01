# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=bazzite
ARG BASE_TAG=stable
# Kernel coordinates for the out-of-tree kmod builder. KERNEL_VERSION is the
# base image's ostree.linux label (resolved in CI / preflight).
ARG KERNEL_FLAVOR=ogc
ARG FEDORA_VERSION=44
ARG KERNEL_VERSION

# Stage providing build_files and system_files to subsequent stages
FROM scratch AS ctx
COPY build_files /build_files
COPY system_files /system_files

# akmods carrier: FROM-scratch image holding /kernel-rpms (incl. kernel-devel)
# matched to the base kernel. Consumed only as an RPM source via bind-mount.
FROM ghcr.io/ublue-os/akmods:${KERNEL_FLAVOR}-${FEDORA_VERSION}-${KERNEL_VERSION} AS akmods-rpms

# kmod-builder: executable base that compiles out-of-tree modules against the
# matched kernel-devel, emitting staged .ko.xz under /out for the final stage.
# Only build_files is mounted: system_files edits must not invalidate the
# BuildKit cache of this stage (kmod compilation is its most expensive step).
FROM ghcr.io/ublue-os/${BASE_IMAGE}:${BASE_TAG} AS kmod-builder
ARG KERNEL_VERSION
RUN --mount=type=bind,from=ctx,source=/build_files,target=/ctx/build_files \
    --mount=type=bind,from=akmods-rpms,source=/kernel-rpms,target=/run/kernel-rpms \
    --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    CTX=/ctx KERNEL_VERSION="${KERNEL_VERSION}" \
    /ctx/build_files/kmods/build-kmods.sh

# Final image
FROM ghcr.io/ublue-os/${BASE_IMAGE}:${BASE_TAG}

ARG BASE_IMAGE
ARG IMAGE_NAME=bazzite-mx
ARG IMAGE_VENDOR=matrixdj96
ARG VERSION=
ARG UPSTREAM_DIGEST=
ARG UPSTREAM_TAG=

# Re-export the build args as ENV so they are visible to the RUN scripts
# (in particular 00-image-info.sh, which keys image-info.json + os-release
# + kcm-about-distrorc on $IMAGE_NAME and $IMAGE_VENDOR).
ENV IMAGE_NAME=${IMAGE_NAME}
ENV IMAGE_VENDOR=${IMAGE_VENDOR}

LABEL org.opencontainers.image.title="${IMAGE_NAME}"
LABEL org.opencontainers.image.vendor="${IMAGE_VENDOR}"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.base.name="ghcr.io/ublue-os/${BASE_IMAGE}:${UPSTREAM_TAG}"
LABEL org.opencontainers.image.base.digest="${UPSTREAM_DIGEST}"
LABEL containers.bootc=1

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=kmod-builder,source=/out,target=/run/kmods \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    CTX=/ctx \
    /ctx/build_files/shared/build.sh

# MX smoke tests. Blocking: every assertion exits 1 on build failure.
# tmpfs on /run: rpm/systemctl probes may touch it, and the runtime-only
# dirs must stay empty in the committed layers (lint below is fatal).
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=tmpfs,dst=/run \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build_files/tests/10-tests-mx.sh

# Fatal: a new warning (runtime-dir residue, /boot content) fails the build
# instead of scrolling by — clean-stage.sh sweeps the two known sources.
RUN bootc container lint --fatal-warnings --no-truncate
