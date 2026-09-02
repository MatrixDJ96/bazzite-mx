#!/usr/bin/env bash
# Checks the smoke tests share. Each prints exactly one OK:/FAIL: line per
# item, the contract run.sh greps. Brings lib/just.sh.
# shellcheck source=../lib/just.sh
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/just.sh"

# check_pkg <pkg>...: every package installed, its version on the OK line.
check_pkg() {
    local pkg
    for pkg in "$@"; do
        if rpm -q "$pkg" > /dev/null; then
            echo "OK: $pkg $(rpm -q --qf '%{VERSION}' "$pkg")"
        else
            echo "FAIL: $pkg not installed"
        fi
    done
}

# check_unit_state [--global] <unit> <expected> [<note>]: is-enabled exits 1
# on "disabled", so || true keeps the state readable.
check_unit_state() {
    local scope="" unit expected note state
    if [ "$1" = --global ]; then
        scope=--global
        shift
    fi
    unit=$1 expected=$2 note=${3:+ ($3)}
    state=$(systemctl ${scope:+"$scope"} is-enabled "$unit" 2>&1 || true)
    if [ "$state" = "$expected" ]; then
        echo "OK: $unit${scope:+ (global)} $expected$note"
    else
        echo "FAIL: $unit${scope:+ (global)} is $state"
    fi
}

# check_desktop_file <path>: a vendor's file that desktop-file-validate only
# warns about still counts, with the warning shown.
check_desktop_file() {
    local desktop=$1 name
    name=$(basename "$desktop")
    if [ -f "$desktop" ] && desktop-file-validate "$desktop" 2> /dev/null; then
        echo "OK: $name valid"
    elif [ -f "$desktop" ]; then
        echo "OK: $name present (desktop-file-validate: $(desktop-file-validate "$desktop" 2>&1 | head -n1))"
    else
        echo "FAIL: $desktop missing"
    fi
}

# check_just_fmt <justfile>: on a copy named justfile, because --fmt formats
# the file it is given only under that name.
check_just_fmt() {
    local file=$1 tmp
    tmp=$(mktemp -d)
    cp "$file" "$tmp/justfile"
    if just --unstable --fmt --check --justfile "$tmp/justfile" > /dev/null 2>&1; then
        echo "OK: $(basename "$file") is just --fmt clean"
    else
        echo "FAIL: $(basename "$file") just --fmt --check: $(just --unstable --fmt --check --justfile "$tmp/justfile" 2>&1 | head -n3 | tr '\n' ' ')"
    fi
    rm -rf "$tmp"
}

# check_recipe_help <justfile> <recipe>: the help action runs and prints its
# usage line. Output is captured first, against the SIGPIPE in lib/just.sh.
check_recipe_help() {
    local file=$1 recipe=$2 out
    out=$(just --justfile "$file" "$recipe" help 2>&1 || true)
    if grep -q "^Usage: ujust $recipe" <<< "$out"; then
        echo "OK: ujust $recipe help runs"
    else
        echo "FAIL: ujust $recipe help: $(head -n2 <<< "$out" | tr '\n' ' ')"
    fi
}

# check_flatpak_deny <ref>: the base's Flatpak filter carries `deny <ref>` once.
check_flatpak_deny() {
    local ref=$1 list=/usr/share/ublue-os/flatpak-blocklist
    if [ -f "$list" ] && [ "$(grep -cxF "deny $ref" "$list")" -eq 1 ]; then
        echo "OK: $list denies $ref (once)"
    else
        echo "FAIL: $list: $(cat "$list" 2>&1 | tr '\n' ';')"
    fi
}
