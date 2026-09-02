#!/usr/bin/env bash
# The recipe set of a ujust file, for the snapshot, the drift guard and every
# test that proves a recipe is defined, and the Bazzite Portal groups whose
# buttons call a recipe the image replaces. Sourced by lib/env.sh and by
# tests/lib.sh.

# The recipe names, sorted, one per line; status 1 when just cannot parse the
# file. A file without recipes exits 0 with nothing on stdout, which is why
# the filter is sed and not grep -v (docs/gotchas.md § `grep -v` on an empty
# set kills a `pipefail` script silently).
recipe_set() {
    local justfile=$1 summary

    if ! summary=$(just --justfile "$justfile" --summary 2> /dev/null); then
        return 1
    fi

    tr ' ' '\n' <<< "$summary" | sed '/^$/d' | sort
}

has_recipe() {
    local justfile=$1 recipe=$2 recipes

    if ! recipes=$(recipe_set "$justfile"); then
        return 1
    fi

    grep -qx -- "$recipe" <<< "$recipes"
}

# remove_portal_group <id>: drops the group <id> of Bazzite's Portal (yafti.yml),
# its `- id:` line and every line indented under it.
remove_portal_group() {
    local id=$1 yafti=/usr/share/yafti/yafti.yml

    awk -v line="      - id: \"$id\"" '
        skip && /^        / { next }
        { skip = 0 }
        $0 == line { skip = 1; next }
        { print }' "$yafti" > "$yafti.new"
    mv "$yafti.new" "$yafti"
}
