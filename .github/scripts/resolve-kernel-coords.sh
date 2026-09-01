#!/usr/bin/env bash
# Resolve the akmods carrier coordinates of an upstream Bazzite image.
#
# Usage:
#   resolve-kernel-coords.sh <base_image> <upstream_tag>
#
# Writes kernel_version=, kernel_flavor= and fedora_version= to
# $GITHUB_OUTPUT (stdout when unset, for local testing).
#
# Single owner of the akmods tag schema: <flavour>-<fedora>-<kernel NVRA>.
# The flavour is DERIVED, never assumed: upstream moves individual flavours
# onto the LTS kernel branch whenever a driver lags the mainline bump (the
# proprietary NVIDIA driver is the recurring case), so bazzite-nvidia rides
# akmods:ogc-lts-* while its siblings ride akmods:ogc-*. A hardcoded flavour
# aborts that flavour's build with "manifest unknown" mid-build.
set -euo pipefail

BASE_IMAGE="${1:?base_image required}"
UPSTREAM_TAG="${2:?upstream_tag required}"

AKMODS_REPO="docker://ghcr.io/ublue-os/akmods"

# The base image's ostree.linux label is the kernel NVRA the akmods carrier
# must match exactly (kernel-devel is bind-mounted from it at build time).
KERNEL_VERSION=$(skopeo inspect --retry-times 3 --no-tags \
  "docker://ghcr.io/ublue-os/${BASE_IMAGE}:${UPSTREAM_TAG}" \
  | jq -r '.Labels["ostree.linux"]')
[ -n "$KERNEL_VERSION" ] && [ "$KERNEL_VERSION" != "null" ] || {
  echo "::error::ostree.linux label missing on ${BASE_IMAGE}:${UPSTREAM_TAG}"
  exit 1
}

# Fedora major comes from the kernel NVRA's own .fcNN component, so the akmods
# suffix is built from a single source and cannot drift from the kernel. The
# presence check comes first: `##*.fc` on a string with no `.fc` returns the
# whole string, whose leading numeric field would pass the digit test.
[[ "$KERNEL_VERSION" == *.fc[0-9]* ]] || {
  echo "::error::no .fcNN component in kernel version ${KERNEL_VERSION}"
  exit 1
}
FEDORA_VERSION="${KERNEL_VERSION##*.fc}"
FEDORA_VERSION="${FEDORA_VERSION%%.*}"
[[ "$FEDORA_VERSION" =~ ^[0-9]+$ ]] || {
  echo "::error::malformed .fcNN component in kernel version ${KERNEL_VERSION}"
  exit 1
}

# Every akmods tag ends with -<fedora>-<kernel NVRA>; what precedes it is the
# flavour. Ask the registry which flavours actually carry this kernel instead
# of maintaining a per-image flavour table that upstream can invalidate.
SUFFIX="-${FEDORA_VERSION}-${KERNEL_VERSION}"
mapfile -t FLAVORS < <(
  skopeo list-tags --retry-times 3 "$AKMODS_REPO" \
    | jq -r --arg s "$SUFFIX" '.Tags[] | select(endswith($s))' \
    | while read -r tag; do echo "${tag%"$SUFFIX"}"; done \
    | sort -u
)

# Fail closed and loud: an empty result means upstream published the image
# before its akmods carrier, and a build started here would die minutes later
# on an unreadable manifest.
[ "${#FLAVORS[@]}" -gt 0 ] || {
  echo "::error::no akmods tag carries kernel ${KERNEL_VERSION} (looked for *${SUFFIX})"
  exit 1
}

# Several flavours can carry the same kernel; they hold the same kernel-devel,
# so prefer the mainline one for build-cache stability and take the first in
# sorted order otherwise.
KERNEL_FLAVOR="${FLAVORS[0]}"
for f in "${FLAVORS[@]}"; do
  if [ "$f" = "ogc" ]; then
    KERNEL_FLAVOR="$f"
    break
  fi
done

{
  echo "kernel_version=$KERNEL_VERSION"
  echo "kernel_flavor=$KERNEL_FLAVOR"
  echo "fedora_version=$FEDORA_VERSION"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
echo "Kernel version: $KERNEL_VERSION"
echo "Kernel flavor: $KERNEL_FLAVOR (akmods:${KERNEL_FLAVOR}${SUFFIX})"
