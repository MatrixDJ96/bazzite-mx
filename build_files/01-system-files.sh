#!/usr/bin/env bash
# Copy system_files/ over the tree. rsync renames each file into place, so a
# base file is replaced on a fresh inode, never written in place. -K writes
# through /opt -> var/opt instead of replacing it (rsync(1), --keep-dirlinks).
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

SRC=$CTX/system_files
[ -d "$SRC" ] || die "no system_files under $CTX"

rsync -rlpvK --no-owner --no-group "$SRC/" /
n=$(find "$SRC" -type f | wc -l)
log "system-files: $n files copied"
