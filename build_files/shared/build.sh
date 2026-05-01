#!/usr/bin/bash
# Top-level build orchestrator for bazzite-mx.
# Runs once per layer build (called from Containerfile).
#
# Style ported from ublue-os/aurora: copy system_files, run flavor-specific
# build (legacy: base / nvidia), optionally overlay DX (IMAGE_TIER=dx),
# then clean and validate repos.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

CTX="${CTX:-/ctx}"
IMAGE_FLAVOR="${IMAGE_FLAVOR:-base}"
IMAGE_TIER="${IMAGE_TIER:-base}"

# Source helper functions
# shellcheck disable=SC1091
source "$CTX/build_files/shared/copr-helpers.sh"

# 1. Copy system_files: shared first, then flavor-specific overlay
if [ -d "$CTX/system_files/shared" ]; then
    rsync -rvKl "$CTX/system_files/shared/" /
fi
if [ -d "$CTX/system_files/$IMAGE_FLAVOR" ]; then
    rsync -rvKl "$CTX/system_files/$IMAGE_FLAVOR/" /
fi

# 2. Flavor-specific build (legacy: base, nvidia, nvidia-open hooks).
#    These scripts are placeholders today; kept intact so future
#    flavor-only customization has a home.
if [ -x "$CTX/build_files/$IMAGE_FLAVOR/build.sh" ]; then
    "$CTX/build_files/$IMAGE_FLAVOR/build.sh"
fi

# 3. DX overlay
if [ "$IMAGE_TIER" = "dx" ]; then
    "$CTX/build_files/shared/build-dx.sh"
fi

# 4. Cleanup + repo isolation validation (build fails if any repo enabled=1)
"$CTX/build_files/shared/clean-stage.sh"
"$CTX/build_files/shared/validate-repos.sh"

echo "::endgroup::"
