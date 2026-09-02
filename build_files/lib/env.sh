#!/usr/bin/env bash
# The paths of a build and the libraries every build script uses. Sourced
# first by every NN-<feature>.sh, which takes its `set` from here; the paths
# derive from this file's own location, so the context works under any mount
# point.
#
# Exports: BUILD_FILES, CTX (the repo root), BUILD_TMP (tmpfs, dies with the
# RUN), BUILD_STATE (ships in the image: the test RUN reads it back).
set -euo pipefail

BUILD_FILES=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
BUILD_FILES=$(realpath "$BUILD_FILES/..")
CTX=$(realpath "$BUILD_FILES/..")
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
