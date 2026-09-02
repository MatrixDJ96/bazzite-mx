#!/usr/bin/env bash
# The recipe set of a ujust file, for the snapshot, the drift guard and every
# test that proves a recipe is defined. Output is captured before any grep:
# `just … | grep -q` under pipefail dies of SIGPIPE when grep stops reading.

# recipe_set <justfile>: the recipe names, sorted, one per line; status 1 when
# just cannot parse the file. A file without recipes exits 0 with nothing on
# stdout, which is why the filter is sed and not grep -v.
recipe_set() {
    local out
    out=$(just --justfile "$1" --summary 2> /dev/null) || return 1
    tr ' ' '\n' <<< "$out" | sed '/^$/d' | sort
}

# has_recipe <justfile> <name>: status 0 when the file defines the recipe.
has_recipe() {
    local set
    set=$(recipe_set "$1") || return 1
    grep -qx -- "$2" <<< "$set"
}
