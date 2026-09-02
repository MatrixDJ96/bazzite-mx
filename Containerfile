# bazzite-mx: one recipe, two flavours. BASE_IMAGE is the only thing that
# differs between them (bazzite / bazzite-nvidia-open); the CI and the local
# pre-flight pass it resolved to a digest by .github/scripts/resolve-base.sh.
#
# Three RUN steps: build (build_files/build.sh runs NN-<feature>.sh in order),
# smoke tests (build_files/tests/run.sh, offline, on the cleaned tree), lint
# (bootc container lint: a warning fails the build — bazzite Containerfile:550,
# aurora Containerfile.in:142-143). The build context is bound at /ctx from a
# scratch stage, never copied into the image (bazzite-dx Containerfile:3-6).
ARG BASE_IMAGE=ghcr.io/ublue-os/bazzite:stable
# Identity (10-image-info.sh): the image name matches the flavour
# (resolve-base.sh prints it), VERSION is the release tag or empty for a
# sandbox/pre-flight build.
ARG IMAGE_NAME=bazzite-mx
ARG IMAGE_VENDOR=matrixdj96
ARG VERSION=

FROM scratch AS ctx
COPY build_files /build_files
COPY system_files /system_files
COPY cosign.pub /cosign.pub

FROM ${BASE_IMAGE}
ARG IMAGE_NAME
ARG IMAGE_VENDOR
ARG VERSION

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
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
