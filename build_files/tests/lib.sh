#!/usr/bin/env bash
# Checks the smoke tests share. Each prints exactly one `OK: …` or `FAIL: …`
# line per item, the contract tests/run.sh reads. Sourced by the tests that
# need them; brings lib/just.sh (recipe_set, has_recipe) and lib/gpg.sh
# (key_fingerprint, KEY_FPR) along.

# shellcheck source=../lib/just.sh
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/just.sh"
# shellcheck source=../lib/gpg.sh
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/gpg.sh"

FLATPAK_BLOCKLIST=/usr/share/ublue-os/flatpak-blocklist

# on_one_line <fallback> [<separator>]: stdin on one line, the separator (a
# blank) between its lines, or the fallback when stdin is empty. A FAIL line
# built with it never ends blank, whatever the probe read.
on_one_line() {
    local fallback=$1 separator=${2:- }
    local text

    text=$(tr '\n' "$separator" || true)
    text=${text%"$separator"}
    printf '%s' "${text:-$fallback}"
}

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

# check_unit_state [--global] <unit> <expected> [<note>]
check_unit_state() {
    local scope="" unit expected note state

    if [ "$1" = --global ]; then
        scope=--global
        shift
    fi

    unit=$1
    expected=$2
    note=${3:+ ($3)}
    state=$(systemctl ${scope:+"$scope"} is-enabled "$unit" 2> /dev/null || true)

    if [ "$state" = "$expected" ]; then
        echo "OK: $unit${scope:+ (global)} $expected$note"
    else
        echo "FAIL: $unit${scope:+ (global)} is" \
            "${state:-without a state (unit missing or unreadable)}"
    fi
}

# check_rpm_key <key id> <name>: dnf5 imported the vendored key at install, so
# the rpm keyring lists its id.
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

# check_key_fingerprint <key file>: the key the image ships carries the
# fingerprint lib/gpg.sh pins for it; a key the table does not know fails, so
# none reaches the image unpinned.
check_key_fingerprint() {
    local key=$1
    local pinned=${KEY_FPR[$key]:-}
    local actual

    actual=$(key_fingerprint "$key" || true)

    if [ -z "$pinned" ]; then
        echo "FAIL: $key has no fingerprint pinned in lib/gpg.sh"
    elif [ "$actual" = "$pinned" ]; then
        echo "OK: $key fingerprint $pinned"
    else
        echo "FAIL: $key fingerprint ${actual:-unreadable}"
    fi
}

# check_self_test <label> <command>...: the command's --self-test exits 0 and
# ends with its `self-test ok` line, which the OK line carries; the FAIL line
# carries the whole output, on one line.
check_self_test() {
    local label=$1
    shift
    local output status

    if output=$("$@" --self-test 2>&1); then
        status=0
    else
        status=$?
    fi

    if [ "$status" -eq 0 ] && grep -q '^self-test ok' <<< "$output"; then
        echo "OK: $label self-test: $(tail -n1 <<< "$output")"
    else
        echo "FAIL: $label self-test (exit $status):" \
            "$(on_one_line 'no output' <<< "$output")"
    fi
}

# check_desktop_file <path>: a vendor's file that desktop-file-validate only
# warns about still counts, with the warning shown; a file it calls an error
# on is one the desktop will not launch, so it fails, as does a Hidden=true
# file, which the desktop treats as deleted.
check_desktop_file() {
    local desktop=$1
    local name findings

    name=$(basename "$desktop")

    if [ ! -f "$desktop" ]; then
        echo "FAIL: $desktop missing"
        return 0
    fi

    if grep -qx 'Hidden=true' "$desktop"; then
        echo "FAIL: $name is Hidden=true: the desktop shows no such entry"
        return 0
    fi

    if desktop-file-validate "$desktop" > /dev/null 2>&1; then
        echo "OK: $name valid"
        return 0
    fi

    findings=$(desktop-file-validate "$desktop" 2>&1 || true)

    if grep -q ': error:' <<< "$findings"; then
        echo "FAIL: $name desktop-file-validate:" \
            "$(grep ': error:' <<< "$findings" | head -n1 | on_one_line 'no output')"
    else
        echo "OK: $name present (desktop-file-validate:" \
            "$(head -n1 <<< "$findings" | on_one_line 'no output'))"
    fi
}

# check_recipe_help <justfile> <recipe>: the help action runs and prints its
# usage line.
check_recipe_help() {
    local file=$1
    local recipe=$2
    local output

    output=$(just --justfile "$file" "$recipe" help 2>&1 || true)

    if grep -q "^Usage: ujust $recipe" <<< "$output"; then
        echo "OK: ujust $recipe help runs"
    else
        echo "FAIL: ujust $recipe help: $(head -n2 <<< "$output" | on_one_line 'no output')"
    fi
}

# check_flatpak_deny <ref>: the base's Flatpak filter carries `deny <ref>` once.
check_flatpak_deny() {
    local ref=$1
    local count lines

    count=$(grep -cxF "deny $ref" "$FLATPAK_BLOCKLIST" 2> /dev/null || true)

    if [ -f "$FLATPAK_BLOCKLIST" ] && [ "$count" -eq 1 ]; then
        echo "OK: $FLATPAK_BLOCKLIST denies $ref (once)"
    else
        lines=$(cat "$FLATPAK_BLOCKLIST" 2>&1 | tr '\n' ';' || true)
        echo "FAIL: $FLATPAK_BLOCKLIST: ${lines:-empty}"
    fi
}
