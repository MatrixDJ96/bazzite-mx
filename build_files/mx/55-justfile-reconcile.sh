#!/usr/bin/bash
# MX block 55: reconcile the ujust justfile tree.
#
# 1. Surgical removal — strips every upstream recipe that bazzite-mx replaces
#    (our versions live in 96-bazzite-mx-overrides.just). Bazzite's master
#    justfile opens with `set allow-duplicate-recipes := true`, so a duplicate
#    name is not an error — it is silently resolved, and just 1.57.0 keeps the
#    FIRST definition it imported (MEASURED 2026-09-01 in the image: two
#    imports defining the same recipe, order swapped, the first one wins both
#    times). Our imports are appended LAST, so without this removal every
#    override would lose to the upstream copy, quietly.
# 2. Import registration — Bazzite's master /usr/share/ublue-os/justfile uses
#    explicit `import` directives (no glob); our files are not loaded by `ujust`
#    until their imports are registered there.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

# shellcheck disable=SC1091
source /ctx/build_files/shared/writeback-helpers.sh

JUST_DIR=/usr/share/ublue-os/just
MASTER=/usr/share/ublue-os/justfile

# --- 1. Surgical removal ---
#
# remove_recipe NAME FILE — edits FILE in place. Runs the awk into a temp file:
# awk exit 0 (recipe header matched) → rewrite FILE from temp, return 0; awk
# exit 3 (header never matched) → drop temp, leave FILE untouched, return 3.
# The `if` guard keeps `set -e` from tripping on the non-match path.
# The rewrite is `cat tmp > FILE`, never `mv tmp FILE`: mktemp creates 0600
# files and mv carries that mode onto the justfile, which ujust then cannot
# read as an unprivileged user. The truncate-write keeps FILE's inode, owner
# and 0644 mode.
#
# The awk is a buffered-lead state machine: comment/attribute lines preceding a
# recipe are held so they can be dropped together with the recipe they decorate,
# but a top-of-file header block (nothing emitted before it) is preserved.
remove_recipe() {
    local name="$1" file="$2" tmp
    tmp="$(mktemp)"
    if awk -v name="$name" '
    function flush_lead(){ for(i=1;i<=nlead;i++){ print lead[i]; emitted=1 } nlead=0 }
    BEGIN{ mode="scan"; found=0; nlead=0; emitted=0 }
    mode=="body"{
        if ($0 ~ /^[ \t]/ || $0=="") next    # body line (indented or blank) → drop
        mode="scan"                            # first col0 non-blank line ends the body
    }
    mode=="scan"{
        if ($0 ~ ("^" name "([ \t][^:]*)?:")) {
            if (emitted==0) flush_lead(); else nlead=0    # keep file header, drop recipe lead
            found=1; mode="body"; next
        }
        if ($0 ~ /^#/ || $0 ~ /^\[/) { lead[++nlead]=$0; next }   # possible lead of next recipe
        flush_lead(); print; emitted=1; next
    }
    END{ flush_lead(); if(!found) exit 3 }
    ' "$file" > "$tmp"; then
        cat "$tmp" > "$file"
        rm -f "$tmp"
    else
        rm -f "$tmp"; return 3
    fi
}

# Manifest: "<recipe> <upstream .just file>".
OVERRIDES=(
    "setup-sunshine 82-bazzite-sunshine.just"
    "setup-virtualization 84-bazzite-virt.just"
    "install-jetbrains-toolbox 82-bazzite-apps.just"
)
for entry in "${OVERRIDES[@]}"; do
    recipe="${entry%% *}"
    file="${entry##* }"
    path="$JUST_DIR/$file"
    if [ ! -f "$path" ]; then
        echo "FAIL: $path not found (did Bazzite change layout?)"
        exit 1
    fi
    if remove_recipe "$recipe" "$path"; then
        echo "Removed upstream recipe '$recipe' from $file."
    else
        echo "FAIL: recipe '$recipe' not found in $file (upstream drift: update the manifest / 96-bazzite-mx-overrides.just)"
        exit 1
    fi
done

# --- 2. Import registration ---
if [ ! -f "$MASTER" ]; then
    echo "FAIL: $MASTER not found (did Bazzite change layout?)"
    exit 1
fi
for f in 95-bazzite-mx.just 96-bazzite-mx-overrides.just; do
    line="import \"$JUST_DIR/$f\""
    if grep -qxF "$line" "$MASTER"; then
        echo "Import for $f already present, skipping."
    else
        {
            echo ""
            echo "# bazzite-mx: $f"
            echo "$line"
        } >> "$MASTER"
        echo "Import for $f appended to master."
    fi
done

# --- 3. Fresh-inode rewrite of every file this script wrote ---
#
# Both writes above land in place on base-image files: the master takes an
# append, the three override files a `cat tmp > file`. Release 44.20260826
# shipped the master with a NUL tail that killed every ujust at parse time
# (gotcha #34); rewrite_fresh_inode is what survives the layer commit —
# class and idiom table: docs/conventions.md § Writing base-image files.
# Shaped after the downstream report from SonnyCavallaro/bazzite-63 (commit
# 5a5b8b2), extended from the master alone to all four written files.
rewrite_fresh_inode "$MASTER" \
    "$JUST_DIR/82-bazzite-sunshine.just" \
    "$JUST_DIR/84-bazzite-virt.just" \
    "$JUST_DIR/82-bazzite-apps.just"

echo "::endgroup::"
