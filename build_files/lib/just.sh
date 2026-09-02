#!/usr/bin/env bash
# The recipe set of a ujust file, for the snapshot, the drift guard and every
# test that proves a recipe is defined. Sourced by lib/env.sh and by
# tests/lib.sh. Output is captured before any grep: `just … | grep -q` under
# pipefail dies of SIGPIPE when grep stops reading.

# The recipe names, sorted, one per line; status 1 when just cannot parse the
# file. A file without recipes exits 0 with nothing on stdout, which is why
# the filter is sed and not grep -v (docs/gotchas.md § `grep -v` on an empty
# set).
recipe_set() {
    local justfile=$1 summary

    if ! summary=$(just --justfile "$justfile" --summary 2> /dev/null); then
        return 1
    fi
    tr ' ' '\n' <<< "$summary" | sed '/^$/d' | sort
}

# Status 0 when the file defines the recipe.
has_recipe() {
    local justfile=$1 recipe=$2 recipes

    if ! recipes=$(recipe_set "$justfile"); then
        return 1
    fi
    grep -qx -- "$recipe" <<< "$recipes"
}
