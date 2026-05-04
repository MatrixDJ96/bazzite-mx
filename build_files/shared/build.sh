#!/usr/bin/bash
# Top-level build orchestrator for bazzite-mx.
# Runs once per layer build (called from Containerfile).
#
# bazzite-mx is a single-flavour distribution. The three GHCR variants
# (bazzite-mx, -nvidia, -nvidia-open) differ only in BASE_IMAGE; the
# build pipeline is identical and applied unconditionally.
# Style ported from ublue-os/aurora: copy system_files, run the
# numbered build steps, clean stage, validate repos are all disabled.

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

# 2. Run the numbered MX build scripts (always-on, no tier toggle)
"$CTX/build_files/shared/build-mx.sh"

# 3. Cleanup + repo isolation validation (build fails if any repo enabled=1)
"$CTX/build_files/shared/clean-stage.sh"
"$CTX/build_files/shared/validate-repos.sh"

echo "::endgroup::"
