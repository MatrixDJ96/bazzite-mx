#!/usr/bin/env bash
# Joins our recipe file to the base justfile. Two facts of just shape every
# guard here: a file that carries a base file's name replaces it, and on a
# duplicate recipe name the earlier import wins.
#
# Usage: 70-justfile.sh              run by build.sh, no arguments
#        70-justfile.sh --self-test  the drift guard on fixtures, `self-test ok: …`
#                                    when it holds
# Reads: $BUILD_STATE/just.base.summary, recorded by 00-prep.sh; a run by hand
#   without it finds no recorded set and passes the drift guard.
# Writes: the import of 95-bazzite-mx.just appended to the master justfile, on
#   a fresh inode; a second run by hand appends it again, which
#   tests/70-justfile.sh refuses.
# Exit status: 0 done; the build stops on a `FAIL: …` line; the self-test
#   exits 1 on its first `self-test: …` or `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

JUST_DIR=/usr/share/ublue-os/just
MASTER=/usr/share/ublue-os/justfile
OURS=95-bazzite-mx.just
VENDORED_DIR=$CTX/system_files/usr/share/ublue-os/just
SNAPSHOT=$BUILD_STATE/just.base.summary

# --- the recipe sets ----------------------------------------------------------

# Prints the recipe set 00-prep.sh recorded for the base file <basename>,
# sorted; status 1 when the base had no such file.
recorded_recipe_set() {
    local snapshot=$1
    local base_name=$2
    local line

    if ! line=$(grep "^$base_name: " "$snapshot"); then
        return 1
    fi

    tr ' ' '\n' <<< "${line#*: }" | sed '/^$/d' | sort
}

one_line() {
    paste -sd ' ' <<< "$1"
}

# --- the drift guard ----------------------------------------------------------

# A vendored file carrying a base file's name must hold the same recipe set
# the base file had: a recipe upstream added would otherwise vanish. A file
# the base does not have passes.
require_same_set_as_base() {
    local snapshot=$1
    local file=$2
    local base_name recorded ours

    base_name=$(basename "$file")

    if ! recorded=$(recorded_recipe_set "$snapshot" "$base_name"); then
        return 0
    fi

    if ! ours=$(recipe_set "$file"); then
        fail_build "$file does not parse"
    fi

    if [ "$ours" != "$recorded" ]; then
        fail_build "$base_name: base recipe set [$(one_line "$recorded")]," \
            "ours [$(one_line "$ours")]"
    fi
}

# --- the self-test ------------------------------------------------------------

# Writes the fixture <dir>/f.just: three recipes, one with attributes and a
# two-line doc comment, and an alias.
write_fixture() {
    local dir=$1

    cat > "$dir/f.just" << 'JUST'
# vim: set ft=make :

# First recipe
[group("a")]
first:
    echo one

# Second recipe, doc comment
# on two lines
[group("b")]
[no-exit-message]
second ACTION="":
    #!/usr/bin/bash
    echo two

    echo "{{ ACTION }}"

alias one := first

# Third
third:
    echo three
JUST
}

# The same set passes, a drifted set is refused, a file the base lacks passes.
self_test_drift_guard() {
    local dir=$1

    cp "$dir/f.just" "$dir/g.just"
    printf 'f.just: first second third\ng.just: first\n' > "$dir/snapshot"

    require_same_set_as_base "$dir/snapshot" "$dir/f.just" > /dev/null

    if (require_same_set_as_base "$dir/snapshot" "$dir/g.just") > /dev/null 2>&1; then
        echo "self-test: a drifted recipe set passed the guard"
        exit 1
    fi

    require_same_set_as_base "$dir/snapshot" "$dir/h.just" > /dev/null
}

self_test() {
    local dir

    dir=$(mktemp -d)
    # shellcheck disable=SC2064  # expand now: the local is gone at EXIT
    trap "rm -rf '$dir'" EXIT

    write_fixture "$dir"
    self_test_drift_guard "$dir"

    echo "self-test ok: drift refused"
}

# --- the build ----------------------------------------------------------------

require_inputs() {
    if [ ! -f "$MASTER" ]; then
        fail_build "$MASTER missing"
    fi
}

guard_vendored_files() {
    local file

    for file in "$VENDORED_DIR"/*.just; do
        require_same_set_as_base "$SNAPSHOT" "$file"
    done
}

import_our_recipes() {
    {
        cat "$MASTER"
        echo "import \"$JUST_DIR/$OURS\""
    } > "$MASTER.new"
    mv -f "$MASTER.new" "$MASTER"
}

require_unique_recipe_names() {
    local file all_names duplicates

    all_names=$(
        for file in "$JUST_DIR"/*.just; do
            recipe_set "$file"
        done | sort || true
    )
    duplicates=$(uniq -d <<< "$all_names")

    if [ -n "$duplicates" ]; then
        fail_build "recipes defined in more than one file (the earlier import would win):" \
            "$(one_line "$duplicates")"
    fi
}

# <master-set> and <our-set> are recipe sets, one name per line.
require_master_exposes_ours() {
    local master_set=$1
    local our_set=$2
    local name

    while IFS= read -r name; do
        if ! grep -qx "$name" <<< "$master_set"; then
            fail_build "$MASTER does not expose $name"
        fi
    done <<< "$our_set"

    if ! just --justfile "$MASTER" --list > /dev/null; then
        fail_build "just --list fails on $MASTER"
    fi
}

# `--check` reads the file it is given under any name and writes nothing.
require_fmt_clean() {
    local file

    for file in "$VENDORED_DIR"/*.just; do
        if ! just --unstable --fmt --check --justfile "$file" > /dev/null 2>&1; then
            fail_build "$(basename "$file") is not just --fmt clean"
        fi
    done
}

# --- main ---------------------------------------------------------------------

if [ "${1:-}" = --self-test ]; then
    self_test
    exit 0
fi

require_inputs
guard_vendored_files
import_our_recipes
require_unique_recipe_names

if ! master_set=$(recipe_set "$MASTER"); then
    fail_build "$MASTER does not parse after the import"
fi

if ! our_set=$(recipe_set "$JUST_DIR/$OURS"); then
    fail_build "$OURS does not parse after the import"
fi

require_master_exposes_ours "$master_set" "$our_set"
require_fmt_clean

log "justfile: $OURS imported ($(wc -l <<< "$our_set") recipes: $(one_line "$our_set"))," \
    "$(wc -l <<< "$master_set") recipes in ujust"
