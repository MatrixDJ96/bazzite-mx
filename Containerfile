# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=bazzite
ARG BASE_TAG=stable

FROM ghcr.io/ublue-os/${BASE_IMAGE}:${BASE_TAG}

ARG BASE_IMAGE
ARG BASE_TAG
ARG IMAGE_NAME=bazzite-mx
ARG IMAGE_VENDOR=matrixdj96
ARG VERSION=
ARG UPSTREAM_DIGEST=
ARG UPSTREAM_TAG=

ENV IMAGE_NAME=${IMAGE_NAME}
ENV IMAGE_VENDOR=${IMAGE_VENDOR}

LABEL org.opencontainers.image.title="${IMAGE_NAME}"
LABEL org.opencontainers.image.vendor="${IMAGE_VENDOR}"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.base.name="ghcr.io/ublue-os/${BASE_IMAGE}:${UPSTREAM_TAG}"
LABEL org.opencontainers.image.base.digest="${UPSTREAM_DIGEST}"
LABEL containers.bootc=1
