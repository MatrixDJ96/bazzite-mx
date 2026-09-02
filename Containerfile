# bazzite-mx: one recipe for the three flavours, which differ in the build
# arg BASE_IMAGE, mapped from the flavour name by
# .github/scripts/resolve-base.sh, the base resolved to a digest. One stage:
# image runs bootc's lint on the base.

ARG BASE_IMAGE=ghcr.io/ublue-os/bazzite:stable

# --- image: lint --------------------------------------------------------------

FROM ${BASE_IMAGE} AS image

# The last gate, offline.
RUN --mount=type=tmpfs,target=/run \
    --network=none \
    bootc container lint --fatal-warnings --no-truncate
