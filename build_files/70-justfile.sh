#!/usr/bin/env bash
# Joins our recipe file to the base justfile. Two facts of just shape every
# guard here: a file that carries a base file's name replaces it, and on a
# duplicate recipe name the earlier import wins.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

JUST_DIR=/usr/share/ublue-os/just
MASTER=/usr/share/ublue-os/justfile
OURS=95-bazzite-mx.just
SNAPSHOT=$BUILD_STATE/just.base.summary
# Base recipes we override in place: <file> <recipe>.
OVERRIDES=(
    "82-bazzite-apps.just install-jetbrains-toolbox"
)

# recorded_set <snapshot> <basename>: the recorded set, or a non-zero status
# when the base had no such file.
recorded_set() {
    local line
    line=$(grep "^$2: " "$1") || return 1
    tr ' ' '\n' <<< "${line#*: }" | sed '/^$/d' | sort
}

# remove_recipe <justfile> <name>: cut the recipe with its doc comments,
# attributes and trailing blank lines, onto a fresh inode. An absent recipe,
# a file that stops parsing, or any other change to the recipe set is fatal:
# a leftover alias to the removed recipe would ship an unparseable file.
remove_recipe() {
    local file=$1 name=$2 before after expected
    before=$(recipe_set "$file")
    grep -qx "$name" <<< "$before" || die "$file: recipe $name not found, nothing to remove"
    awk -v name="$name" '
        {
            lines[NR] = $0
        }
        END {
            h = 0
            for (i = 1; i <= NR; i++) {
                if (lines[i] ~ ("^" name "([ \t]|:)") && lines[i] !~ /:=/) { h = i; break }
            }
            if (h == 0) exit 2
            s = h
            while (s > 1 && lines[s - 1] ~ /^(#|\[)/) s--
            e = h
            for (i = h + 1; i <= NR; i++) {
                if (lines[i] ~ /^[ \t]+[^ \t]/) e = i
                else if (lines[i] != "") break
            }
            t = e
            while (t < NR && lines[t + 1] == "") t++
            for (i = 1; i <= NR; i++) {
                if (i < s || i > t) print lines[i]
            }
        }
    ' "$file" > "$file.new" || die "$file: awk found no header for $name"
    mv -f "$file.new" "$file"
    after=$(recipe_set "$file") || die "$file no longer parses after removing $name"
    expected=$(grep -vx "$name" <<< "$before")
    [ "$after" = "$expected" ] || die "$file: recipe set after removing $name: [$(tr '\n' ' ' <<< "$after")], expected [$(tr '\n' ' ' <<< "$expected")]"
    ! grep -q "^$name\([ \t]\|:\)" "$file" || die "$file: a header of $name survived"
}

# guard_replaced <snapshot> <vendored-file>: a vendored file carrying a base
# file's name must hold the same recipe set the base file had.
guard_replaced() {
    local snapshot=$1 file=$2 base ours recorded
    base=$(basename "$file")
    recorded=$(recorded_set "$snapshot" "$base") || return 0
    ours=$(recipe_set "$file")
    [ "$ours" = "$recorded" ] || die "$base: base recipe set [$(tr '\n' ' ' <<< "$recorded")], ours [$(tr '\n' ' ' <<< "$ours")]"
}

self_test() {
    local d
    d=$(mktemp -d)
    # shellcheck disable=SC2064  # expand now: the local is gone at EXIT
    trap "rm -rf '$d'" EXIT
    cat > "$d/f.just" << 'EOF'
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
EOF
    cp "$d/f.just" "$d/g.just"
    remove_recipe "$d/g.just" second
    [ "$(recipe_set "$d/g.just" | tr '\n' ' ')" = "first third " ] || {
        echo "self-test: remove_recipe left [$(recipe_set "$d/g.just" | tr '\n' ' ')]"
        exit 1
    }
    [ "$(grep -c '' "$d/g.just")" -eq 12 ] || {
        echo "self-test: expected 12 lines after the removal, got $(grep -c '' "$d/g.just")"
        exit 1
    }
    grep -qx 'alias one := first' "$d/g.just" && grep -qx 'third:' "$d/g.just" && grep -qx '    echo one' "$d/g.just" || {
        echo "self-test: a neighbour recipe or alias was damaged"
        exit 1
    }
    [ "$(sed -n '7,8p' "$d/g.just" | tr '\n' '|')" = "|alias one := first|" ] || {
        echo "self-test: blank-line separation changed around the removed block"
        exit 1
    }
    if (remove_recipe "$d/g.just" second) > /dev/null 2>&1; then
        echo "self-test: removing an absent recipe passed"
        exit 1
    fi
    # An alias pointing at the removed recipe leaves a file just cannot parse.
    sed 's/^alias one := first/alias two := second/' "$d/f.just" > "$d/a.just"
    if (remove_recipe "$d/a.just" second) > /dev/null 2>&1; then
        echo "self-test: a removal that orphaned an alias passed"
        exit 1
    fi
    printf 'f.just: first second third\ng.just: first\n' > "$d/snapshot"
    guard_replaced "$d/snapshot" "$d/f.just" > /dev/null || {
        echo "self-test: an identical recipe set was refused"
        exit 1
    }
    if (guard_replaced "$d/snapshot" "$d/g.just") > /dev/null 2>&1; then
        echo "self-test: a drifted recipe set passed the guard"
        exit 1
    fi
    guard_replaced "$d/snapshot" "$d/h.just" > /dev/null || {
        echo "self-test: a file the base does not have was refused"
        exit 1
    }
    echo "self-test ok: recipe removed whole, absent recipe refused, drift refused"
}

if [ "${1:-}" = --self-test ]; then
    self_test
    exit 0
fi

[ -s "$SNAPSHOT" ] || die "$SNAPSHOT missing: 00-prep.sh did not record the base's recipe files"
[ -f "$MASTER" ] || die "$MASTER missing"
[ -f "$JUST_DIR/$OURS" ] || die "$JUST_DIR/$OURS missing"

for f in "$CTX"/system_files/usr/share/ublue-os/just/*.just; do
    guard_replaced "$SNAPSHOT" "$f"
done

for entry in "${OVERRIDES[@]}"; do
    read -r file name <<< "$entry"
    [ -f "$JUST_DIR/$file" ] || die "$JUST_DIR/$file missing"
    ! grep -q "^$file: " "$SNAPSHOT" || recorded_set "$SNAPSHOT" "$file" | grep -qx "$name" \
        || die "$file: the base no longer defines $name; drop it from OVERRIDES"
    recipe_set "$JUST_DIR/$OURS" | grep -qx "$name" || die "$OURS does not define $name, nothing overrides the base's"
    remove_recipe "$JUST_DIR/$file" "$name"
done

# The import goes on once: a second run would duplicate every recipe name.
grep -q "import \"$JUST_DIR/$OURS\"" "$MASTER" && die "$MASTER already imports $OURS"
{
    cat "$MASTER"
    echo "import \"$JUST_DIR/$OURS\""
} > "$MASTER.new"
mv -f "$MASTER.new" "$MASTER"

# On a duplicate name the earlier import wins, so a duplicate is fatal here.
all=$(for f in "$JUST_DIR"/*.just; do recipe_set "$f"; done | sort)
dups=$(uniq -d <<< "$all")
[ -z "$dups" ] || die "recipes defined in more than one file (the earlier import would win): $(tr '\n' ' ' <<< "$dups")"
master_set=$(recipe_set "$MASTER") || die "$MASTER does not parse after the import"
ours=$(recipe_set "$JUST_DIR/$OURS")
while IFS= read -r name; do
    grep -qx "$name" <<< "$master_set" || die "$MASTER does not expose $name"
done <<< "$ours"
just --justfile "$MASTER" --list > /dev/null || die "just --list fails on $MASTER"

for f in "$CTX"/system_files/usr/share/ublue-os/just/*.just; do
    tmp=$(mktemp -d)
    cp "$f" "$tmp/justfile"
    just --unstable --fmt --check --justfile "$tmp/justfile" > /dev/null 2>&1 || die "$(basename "$f") is not just --fmt clean"
    rm -rf "$tmp"
done

log "justfile: $OURS imported ($(wc -l <<< "$ours") recipes: $(tr '\n' ' ' <<< "$ours")), ${#OVERRIDES[@]} base recipe(s) overridden, $(wc -l <<< "$master_set") recipes in ujust"
