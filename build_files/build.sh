#!/usr/bin/env bash
# Orchestrator: runs build_files/NN-<feature>.sh in version order, each in a
# ::group::, stopping at the first failure. The file names are the only
# statement of the order.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

mapfile -t scripts < <(find "$BUILD_FILES" -maxdepth 1 -name '[0-9][0-9]-*.sh' -type f | sort -V)
[ ${#scripts[@]} -gt 0 ] || die "no build scripts under $BUILD_FILES"

for script in "${scripts[@]}"; do
    group "$(basename "$script")"
    bash "$script"
    endgroup
done
log "build.sh: ${#scripts[@]} scripts ran"
