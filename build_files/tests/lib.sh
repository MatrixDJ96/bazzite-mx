#!/usr/bin/env bash
# Checks the smoke tests share. Each prints exactly one `OK: …` or `FAIL: …`
# line per item, the contract tests/run.sh reads. Sourced by the tests that
# need them; brings lib/just.sh (recipe_set, has_recipe) along.

# shellcheck source=../lib/just.sh
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/just.sh"

FLATPAK_BLOCKLIST=/usr/share/ublue-os/flatpak-blocklist

# check_pkg <pkg>...: every package installed, its version on the OK line.
check_pkg() {
    local package

    for package in "$@"; do
        if rpm -q "$package" > /dev/null; then
            echo "OK: $package $(rpm -q --qf '%{VERSION}' "$package")"
        else
            echo "FAIL: $package not installed"
        fi
    done
}

# check_unit_state [--global] <unit> <expected> [<note>]: is-enabled exits 1
# on a disabled unit, so its status is dropped and the printed state compared.
check_unit_state() {
    local scope="" unit expected note state

    if [ "$1" = --global ]; then
        scope=--global
        shift
    fi

    unit=$1
    expected=$2
    note=${3:+ ($3)}
    state=$(systemctl ${scope:+"$scope"} is-enabled "$unit" 2>&1 || true)

    if [ "$state" = "$expected" ]; then
        echo "OK: $unit${scope:+ (global)} $expected$note"
    else
        echo "FAIL: $unit${scope:+ (global)} is $state"
    fi
}

# check_rpm_key <key id> <name>: dnf5 imported the vendored key at install, so
# the rpm keyring lists its id. The list is captured first: `rpm -q | grep -q`
# dies of SIGPIPE under pipefail once in a few hundred runs
# (docs/gotchas.md § `command | grep -q` under `pipefail`).
check_rpm_key() {
    local key_id=$1
    local name=$2
    local keys

    keys=$(rpm -q gpg-pubkey --qf '%{VERSION}\n' 2> /dev/null || true)

    if grep -qi "$key_id\$" <<< "$keys"; then
        echo "OK: $name key in the rpm keyring"
    else
        echo "FAIL: $name key (…$key_id) not in the rpm keyring"
    fi
}

# check_desktop_file <path>: a vendor's file that desktop-file-validate only
# warns about still counts, with the warning shown.
check_desktop_file() {
    local desktop=$1
    local name warning

    name=$(basename "$desktop")

    if [ ! -f "$desktop" ]; then
        echo "FAIL: $desktop missing"
        return 0
    fi

    if desktop-file-validate "$desktop" 2> /dev/null; then
        echo "OK: $name valid"
    else
        warning=$(desktop-file-validate "$desktop" 2>&1 | head -n1)
        echo "OK: $name present (desktop-file-validate: $warning)"
    fi
}

# check_just_fmt <justfile>: on a copy named justfile, because --fmt formats
# the file it is given only under that name.
check_just_fmt() {
    local file=$1
    local tmp findings

    tmp=$(mktemp -d)
    cp "$file" "$tmp/justfile"

    if just --unstable --fmt --check --justfile "$tmp/justfile" > /dev/null 2>&1; then
        echo "OK: $(basename "$file") is just --fmt clean"
    else
        findings=$(just --unstable --fmt --check --justfile "$tmp/justfile" 2>&1 \
            | head -n3 \
            | tr '\n' ' ')
        echo "FAIL: $(basename "$file") just --fmt --check: $findings"
    fi

    rm -rf "$tmp"
}

# check_recipe_help <justfile> <recipe>: the help action runs and prints its
# usage line. Output is captured first, against the SIGPIPE in lib/just.sh.
check_recipe_help() {
    local file=$1
    local recipe=$2
    local output

    output=$(just --justfile "$file" "$recipe" help 2>&1 || true)

    if grep -q "^Usage: ujust $recipe" <<< "$output"; then
        echo "OK: ujust $recipe help runs"
    else
        echo "FAIL: ujust $recipe help: $(head -n2 <<< "$output" | tr '\n' ' ')"
    fi
}

# check_flatpak_deny <ref>: the base's Flatpak filter carries `deny <ref>` once.
check_flatpak_deny() {
    local ref=$1
    local count

    count=$(grep -cxF "deny $ref" "$FLATPAK_BLOCKLIST" 2> /dev/null || true)

    if [ -f "$FLATPAK_BLOCKLIST" ] && [ "$count" -eq 1 ]; then
        echo "OK: $FLATPAK_BLOCKLIST denies $ref (once)"
    else
        echo "FAIL: $FLATPAK_BLOCKLIST: $(cat "$FLATPAK_BLOCKLIST" 2>&1 | tr '\n' ';')"
    fi
}
