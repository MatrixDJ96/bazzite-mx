#!/usr/bin/env bash
# Copy system_files/ over the tree. rsync renames each file into place, so a
# base file is replaced on a fresh inode, never written in place; -K writes
# through the /opt -> var/opt link instead of replacing it (rsync(1),
# --keep-dirlinks).
#
# Usage: run by build.sh after 00-prep.sh; no arguments.
# Writes: every file under system_files/, at the same path under /.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

SOURCE_TREE=$CTX/system_files

if [ ! -d "$SOURCE_TREE" ]; then
    fail_build "no system_files under $CTX"
fi

rsync -rlpvK --no-owner --no-group "$SOURCE_TREE/" /

file_count=$(find "$SOURCE_TREE" -type f | wc -l)
log "system-files: $file_count files copied"
