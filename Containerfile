# bazzite-mx: one recipe, two flavours. BASE_IMAGE is the only thing that
# differs between them (bazzite / bazzite-nvidia-open); the CI and the local
# pre-flight pass it resolved to a digest by .github/scripts/resolve-base.sh.
#
# Stages, scripts and tests arrive one feature at a time, each with its own
# smoke test. The lint step is the image's exit gate: a warning fails the build
# (bazzite Containerfile:550, aurora Containerfile.in:142-143).
ARG BASE_IMAGE=ghcr.io/ublue-os/bazzite:stable

FROM ${BASE_IMAGE}

RUN --mount=type=tmpfs,target=/run \
    --network=none \
    bootc container lint --fatal-warnings --no-truncate
