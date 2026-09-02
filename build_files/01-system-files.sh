#!/usr/bin/env bash
# Copy system_files/ over the tree. rsync renames each file into place, so a
# base file is replaced on a fresh inode, never written in place; -K writes
# through the /opt -> var/opt link instead of replacing it (rsync(1),
# --keep-dirlinks). The groups whose gid the image fixes are created next,
# before a package's scriptlet or sysusers file allocates them dynamically.
#
# Usage: run by build.sh after 00-prep.sh; no arguments.
# Writes: every file under system_files/, at the same path under /; the
#   groups of /usr/lib/sysusers.d/bazzite-mx-groups.conf in /etc/group.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

SOURCE_TREE=$CTX/system_files
FIXED_GROUPS=/usr/lib/sysusers.d/bazzite-mx-groups.conf

rsync -rlpvK --no-owner --no-group "$SOURCE_TREE/" /

systemd-sysusers "$FIXED_GROUPS"

file_count=$(find "$SOURCE_TREE" -type f | wc -l || true)
log "system-files: $file_count files copied"
