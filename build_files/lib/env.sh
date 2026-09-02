#!/usr/bin/env bash
# Paths and shared helpers, sourced first by every build script. Paths derive
# from this file's own location, so the context works under any mount point.
set -euo pipefail

BUILD_FILES=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
BUILD_FILES=$(realpath "$BUILD_FILES/..")
CTX=$(realpath "$BUILD_FILES/..")
# BUILD_TMP is tmpfs and dies with the RUN; BUILD_STATE ships in the image,
# because the test RUN reads it back.
BUILD_TMP=${BUILD_TMP:-/tmp/bazzite-mx-build}
BUILD_STATE=${BUILD_STATE:-/usr/lib/bazzite-mx/build-state}
export BUILD_FILES CTX BUILD_TMP BUILD_STATE
mkdir -p "$BUILD_TMP" "$BUILD_STATE"

# shellcheck source=log.sh
source "$BUILD_FILES/lib/log.sh"
# shellcheck source=repos.sh
source "$BUILD_FILES/lib/repos.sh"
# shellcheck source=gpg.sh
source "$BUILD_FILES/lib/gpg.sh"
# shellcheck source=just.sh
source "$BUILD_FILES/lib/just.sh"
# shellcheck source=flatpak.sh
source "$BUILD_FILES/lib/flatpak.sh"
