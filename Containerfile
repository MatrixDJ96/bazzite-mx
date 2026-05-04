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

# bazzite-mx is a single-flavour distribution. The three GHCR variants
# (bazzite-mx, -nvidia, -nvidia-open) differ only in BASE_IMAGE; the
# build pipeline is identical and applied unconditionally.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    CTX=/ctx \
    /ctx/build_files/shared/build.sh

# MX smoke tests. Blocking: every assertion exits 1 on build failure.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/build_files/tests/10-tests-mx.sh

RUN bootc container lint
