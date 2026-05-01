# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=bazzite
ARG BASE_TAG=stable

# Stage providing build_files and system_files to subsequent stages
FROM scratch AS ctx
COPY build_files /build_files
COPY system_files /system_files

# Final image
FROM ghcr.io/ublue-os/${BASE_IMAGE}:${BASE_TAG}

ARG BASE_IMAGE
ARG BASE_TAG
ARG IMAGE_FLAVOR=base
# Valid: base | nvidia
ARG IMAGE_TIER=base
# Valid: base | dx
ARG IMAGE_NAME=bazzite-mx
ARG IMAGE_VENDOR=matrixdj96
ARG VERSION=
ARG UPSTREAM_DIGEST=
ARG UPSTREAM_TAG=

LABEL org.opencontainers.image.title="${IMAGE_NAME}"
LABEL org.opencontainers.image.vendor="${IMAGE_VENDOR}"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.base.name="ghcr.io/ublue-os/${BASE_IMAGE}:${UPSTREAM_TAG}"
LABEL org.opencontainers.image.base.digest="${UPSTREAM_DIGEST}"
LABEL containers.bootc=1

# Single orchestrated build pass: build.sh handles system_files copy,
# flavor-specific hooks (base/nvidia), DX overlay (when IMAGE_TIER=dx),
# cleanup, and repo-isolation validation.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    CTX=/ctx \
    IMAGE_FLAVOR="${IMAGE_FLAVOR}" \
    IMAGE_TIER="${IMAGE_TIER}" \
    /ctx/build_files/shared/build.sh

# DX smoke tests (only when IMAGE_TIER=dx). Bloccante.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    if [ "${IMAGE_TIER}" = "dx" ]; then /ctx/build_files/tests/10-tests-dx.sh; fi

RUN bootc container lint
