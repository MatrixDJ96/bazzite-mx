#!/usr/bin/bash
# Top-level build orchestrator for bazzite-mx.
# Runs once per layer build (called from Containerfile).
#
# bazzite-mx is single-flavour: MX = Bazzite + DX overlay. The three GHCR
# variants (bazzite-mx, -nvidia, -nvidia-open) differ only in BASE_IMAGE.
# Style ported from ublue-os/aurora: copy system_files, apply DX overlay,
# clean stage, validate repos are all disabled.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

CTX="${CTX:-/ctx}"

# Source helper functions
# shellcheck disable=SC1091
source "$CTX/build_files/shared/copr-helpers.sh"

# 1. Copy system_files
if [ -d "$CTX/system_files" ]; then
    rsync -rvKl "$CTX/system_files/" /
fi

# 2. DX overlay (always-on: MX = Bazzite + DX)
"$CTX/build_files/shared/build-dx.sh"

# 3. Cleanup + repo isolation validation (build fails if any repo enabled=1)
"$CTX/build_files/shared/clean-stage.sh"
"$CTX/build_files/shared/validate-repos.sh"

echo "::endgroup::"
