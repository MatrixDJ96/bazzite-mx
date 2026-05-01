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

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    if [ -d /ctx/system_files/shared ]; then cp -a /ctx/system_files/shared/. / 2>/dev/null || true; fi && \
    if [ -d /ctx/system_files/${IMAGE_FLAVOR} ]; then cp -a /ctx/system_files/${IMAGE_FLAVOR}/. / 2>/dev/null || true; fi && \
    /ctx/build_files/shared/build.sh && \
    /ctx/build_files/${IMAGE_FLAVOR}/build.sh

RUN bootc container lint
