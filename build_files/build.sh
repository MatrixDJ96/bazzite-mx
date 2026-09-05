#!/usr/bin/env bash
# Orchestrator: runs build_files/NN-<feature>.sh in version order, each in a
# ::group::, stopping at the first failure. The file names are the only
# statement of the order.
#
# Usage: run by the Containerfile's build RUN; no arguments.
# Output: the scripts' own, each folded in a group; `build.sh: N scripts ran`
#   at the end, the line preflight-build.sh reads.
# Exit status: 0 when every script did; the first failing script's otherwise.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

mapfile -t scripts < <(find "$BUILD_FILES" -maxdepth 1 -name '[0-9][0-9]-*.sh' -type f | sort -V)

if [ ${#scripts[@]} -eq 0 ]; then
    fail_build "no build scripts under $BUILD_FILES"
fi

for script in "${scripts[@]}"; do
    group "$(basename "$script")"
    bash "$script"
    endgroup
done

log "build.sh: ${#scripts[@]} scripts ran"
