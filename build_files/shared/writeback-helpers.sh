#!/usr/bin/bash
# Torn-writeback helper: rewrite a base-image file onto a fresh inode.
#
# The runner kernel loses page writeback of in-place writes into copied-up
# overlay files, so the committed layer ships a NUL tail while the build
# stays green. The rule: a script whose last write to a base-image file is
# in place calls rewrite_fresh_inode on it before it exits. Full class,
# measured idiom table and production hits: docs/conventions.md
# § "Writing base-image files" and gotcha #34.
set -euo pipefail

# rewrite_fresh_inode FILE... — copy each file onto a brand-new inode,
# fsync it, and rename it over the original. Mode, ownership and timestamps
# carry over, so the justfile tree keeps the 0644 that ujust needs.
rewrite_fresh_inode() {
    local f
    for f in "$@"; do
        if [ ! -f "$f" ]; then
            echo "FAIL: rewrite_fresh_inode: $f is not a regular file"
            return 1
        fi
        cp --preserve=mode,ownership,timestamps "$f" "${f}.fresh"
        sync "${f}.fresh"
        mv "${f}.fresh" "$f"
    done
    sync
}
