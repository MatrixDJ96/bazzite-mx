#!/usr/bin/env bash
# Joins our recipe file to the base justfile. Two facts of just shape every
# guard here: a file that carries a base file's name replaces it, and on a
# duplicate recipe name the earlier import wins.
#
# Usage: 70-justfile.sh              run by build.sh, no arguments
#        70-justfile.sh --self-test  the recipe removal and the drift guard on
#                                    fixtures, `self-test ok: …` when they hold
# Reads: $BUILD_STATE/just.base.summary, recorded by 00-prep.sh.
# Writes: each base recipe in OVERRIDES cut out of its file; the import of
#   95-bazzite-mx.just appended to the master justfile, on a fresh inode.
# Exit status: 0 done; the build stops on a `FAIL: …` line; the self-test
#   exits 1 on its first `self-test: …` finding.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

JUST_DIR=/usr/share/ublue-os/just
MASTER=/usr/share/ublue-os/justfile
OURS=95-bazzite-mx.just
VENDORED_DIR=$CTX/system_files/usr/share/ublue-os/just
SNAPSHOT=$BUILD_STATE/just.base.summary

# Base recipes we override in place: `<file> <recipe>`. The recipe is cut out
# of the base file so ours, imported later, is the one just runs.
OVERRIDES=(
    "82-bazzite-apps.just install-jetbrains-toolbox"
)

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

# Prints a recipe set on one line, for a message.
one_line() {
    tr '\n' ' ' <<< "$1"
}

# --- removing a base recipe ---------------------------------------------------

# Writes <justfile>.new without the recipe <name>: its doc comments and
# attributes above, its body below, and the blank lines after it. Status 2
# when no header of <name> is found. A `name :=` line is an assignment, not
# a header.
cut_recipe_block() {
    local file=$1
    local name=$2

    awk -v name="$name" '
        {
            lines[NR] = $0
        }
        END {
            header = 0
            for (i = 1; i <= NR; i++) {
                if (lines[i] ~ ("^" name "([ \t]|:)") && lines[i] !~ /:=/) {
                    header = i
                    break
                }
            }
            if (header == 0) {
                exit 2
            }

            start = header
            while (start > 1 && lines[start - 1] ~ /^(#|\[)/) {
                start--
            }

            end = header
            for (i = header + 1; i <= NR; i++) {
                if (lines[i] ~ /^[ \t]+[^ \t]/) {
                    end = i
                } else if (lines[i] != "") {
                    break
                }
            }
            while (end < NR && lines[end + 1] == "") {
                end++
            }

            for (i = 1; i <= NR; i++) {
                if (i < start || i > end) {
                    print lines[i]
                }
            }
        }
    ' "$file" > "$file.new"
}

# The file must still parse and its set must have lost exactly <name>: a
# leftover alias to the removed recipe would ship an unparseable file.
require_removal_clean() {
    local file=$1
    local name=$2
    local set_before=$3
    local set_after expected

    if ! set_after=$(recipe_set "$file"); then
        fail_build "$file no longer parses after removing $name"
    fi

    expected=$(grep -vx "$name" <<< "$set_before")

    if [ "$set_after" != "$expected" ]; then
        fail_build "$file: recipe set after removing $name:" \
            "[$(one_line "$set_after")], expected [$(one_line "$expected")]"
    fi

    if grep -q "^$name\([ \t]\|:\)" "$file"; then
        fail_build "$file: a header of $name survived"
    fi
}

# Cuts the recipe <name> out of <justfile>, onto a fresh inode.
remove_recipe() {
    local file=$1
    local name=$2
    local set_before

    set_before=$(recipe_set "$file")

    if ! grep -qx "$name" <<< "$set_before"; then
        fail_build "$file: recipe $name not found, nothing to remove"
    fi

    if ! cut_recipe_block "$file" "$name"; then
        fail_build "$file: awk found no header for $name"
    fi

    mv -f "$file.new" "$file"
    require_removal_clean "$file" "$name" "$set_before"
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

    ours=$(recipe_set "$file")

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

# The middle recipe goes whole, its neighbours and the alias stay, and the
# blank-line separation around the cut is kept.
self_test_remove_recipe() {
    local dir=$1
    local file=$dir/g.just
    local remaining

    cp "$dir/f.just" "$file"
    remove_recipe "$file" second
    remaining=$(recipe_set "$file" | tr '\n' ' ')

    if [ "$remaining" != "first third " ]; then
        echo "self-test: remove_recipe left [$remaining]"
        exit 1
    fi

    if [ "$(grep -c '' "$file")" -ne 12 ]; then
        echo "self-test: expected 12 lines after the removal, got $(grep -c '' "$file")"
        exit 1
    fi

    if ! grep -qx 'alias one := first' "$file" \
        || ! grep -qx 'third:' "$file" \
        || ! grep -qx '    echo one' "$file"; then
        echo "self-test: a neighbour recipe or alias was damaged"
        exit 1
    fi

    if [ "$(sed -n '7,8p' "$file" | tr '\n' '|')" != "|alias one := first|" ]; then
        echo "self-test: blank-line separation changed around the removed block"
        exit 1
    fi
}

# Removing an absent recipe is refused, and so is a removal that leaves an
# alias pointing at nothing: just could not parse the file.
self_test_refusals() {
    local dir=$1

    if (remove_recipe "$dir/g.just" second) > /dev/null 2>&1; then
        echo "self-test: removing an absent recipe passed"
        exit 1
    fi

    sed 's/^alias one := first/alias two := second/' "$dir/f.just" > "$dir/a.just"

    if (remove_recipe "$dir/a.just" second) > /dev/null 2>&1; then
        echo "self-test: a removal that orphaned an alias passed"
        exit 1
    fi
}

# The same set passes, a drifted set is refused, a file the base lacks passes.
self_test_drift_guard() {
    local dir=$1

    printf 'f.just: first second third\ng.just: first\n' > "$dir/snapshot"

    if ! require_same_set_as_base "$dir/snapshot" "$dir/f.just" > /dev/null; then
        echo "self-test: an identical recipe set was refused"
        exit 1
    fi

    if (require_same_set_as_base "$dir/snapshot" "$dir/g.just") > /dev/null 2>&1; then
        echo "self-test: a drifted recipe set passed the guard"
        exit 1
    fi

    if ! require_same_set_as_base "$dir/snapshot" "$dir/h.just" > /dev/null; then
        echo "self-test: a file the base does not have was refused"
        exit 1
    fi
}

self_test() {
    local dir

    dir=$(mktemp -d)
    # shellcheck disable=SC2064  # expand now: the local is gone at EXIT
    trap "rm -rf '$dir'" EXIT

    write_fixture "$dir"
    self_test_remove_recipe "$dir"
    self_test_refusals "$dir"
    self_test_drift_guard "$dir"

    echo "self-test ok: recipe removed whole, absent recipe refused, drift refused"
}

# --- the build ----------------------------------------------------------------

require_inputs() {
    if [ ! -s "$SNAPSHOT" ]; then
        fail_build "$SNAPSHOT missing: 00-prep.sh did not record the base's recipe files"
    fi

    if [ ! -f "$MASTER" ]; then
        fail_build "$MASTER missing"
    fi

    if [ ! -f "$JUST_DIR/$OURS" ]; then
        fail_build "$JUST_DIR/$OURS missing"
    fi
}

guard_vendored_files() {
    local file

    for file in "$VENDORED_DIR"/*.just; do
        require_same_set_as_base "$SNAPSHOT" "$file"
    done
}

# Each override needs the base recipe still there, recorded by 00-prep.sh
# when the base file is, and ours defined, or nothing would replace it.
apply_overrides() {
    local entry file name recorded_recipes our_recipes

    for entry in "${OVERRIDES[@]}"; do
        read -r file name <<< "$entry"

        if [ ! -f "$JUST_DIR/$file" ]; then
            fail_build "$JUST_DIR/$file missing"
        fi

        if grep -q "^$file: " "$SNAPSHOT"; then
            recorded_recipes=$(recorded_recipe_set "$SNAPSHOT" "$file")
            if ! grep -qx "$name" <<< "$recorded_recipes"; then
                fail_build "$file: the base no longer defines $name; drop it from OVERRIDES"
            fi
        fi

        our_recipes=$(recipe_set "$JUST_DIR/$OURS")
        if ! grep -qx "$name" <<< "$our_recipes"; then
            fail_build "$OURS does not define $name, nothing overrides the base's"
        fi

        remove_recipe "$JUST_DIR/$file" "$name"
    done
}

# The import goes on once: a second run would duplicate every recipe name.
import_our_recipes() {
    if grep -q "import \"$JUST_DIR/$OURS\"" "$MASTER"; then
        fail_build "$MASTER already imports $OURS"
    fi

    {
        cat "$MASTER"
        echo "import \"$JUST_DIR/$OURS\""
    } > "$MASTER.new"
    mv -f "$MASTER.new" "$MASTER"
}

# On a duplicate name the earlier import wins, so a duplicate is fatal here.
require_unique_recipe_names() {
    local file all_names duplicates

    all_names=$(
        for file in "$JUST_DIR"/*.just; do
            recipe_set "$file"
        done | sort
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

# just --fmt --check wants the file named justfile, hence the copy.
require_fmt_clean() {
    local file tmp

    for file in "$VENDORED_DIR"/*.just; do
        tmp=$(mktemp -d)
        cp "$file" "$tmp/justfile"

        if ! just --unstable --fmt --check --justfile "$tmp/justfile" > /dev/null 2>&1; then
            fail_build "$(basename "$file") is not just --fmt clean"
        fi

        rm -rf "$tmp"
    done
}

# --- main ---------------------------------------------------------------------

if [ "${1:-}" = --self-test ]; then
    self_test
    exit 0
fi

require_inputs
guard_vendored_files
apply_overrides
import_our_recipes
require_unique_recipe_names

if ! master_set=$(recipe_set "$MASTER"); then
    fail_build "$MASTER does not parse after the import"
fi

our_set=$(recipe_set "$JUST_DIR/$OURS")
require_master_exposes_ours "$master_set" "$our_set"
require_fmt_clean

log "justfile: $OURS imported ($(wc -l <<< "$our_set") recipes: $(one_line "$our_set"))," \
    "${#OVERRIDES[@]} base recipe(s) overridden, $(wc -l <<< "$master_set") recipes in ujust"
