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

# check_repo_reads_key <repo> <key file>: the vendored .repo reads the key
# from its file with gpgcheck on.
check_repo_reads_key() {
    local repo=$1
    local key=$2
    local gpg_lines

    if grep -qx "gpgkey=file://$key" "$repo" 2> /dev/null \
        && grep -qx 'gpgcheck=1' "$repo" 2> /dev/null; then
        echo "OK: $repo reads the vendored key with gpgcheck=1"
    else
        gpg_lines=$(grep -E '^gpg' "$repo" 2>&1 | tr '\n' ' ' || true)
        echo "FAIL: $repo: ${gpg_lines:-no gpg line}"
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

# check_portal_group_removed <id> <next>: the base's Portal, parsed as YAML,
# has no group <id> and still has the group <next> after it.
check_portal_group_removed() {
    local id=$1 next=$2

    if python3 - "$id" "$next" << 'EOF'; then
import sys, yaml
ids = set()
def walk(node):
    if isinstance(node, dict):
        if "id" in node:
            ids.add(node["id"])
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
walk(yaml.safe_load(open("/usr/share/yafti/yafti.yml")))
sys.exit(0 if sys.argv[1] not in ids and sys.argv[2] in ids else 1)
EOF
        echo "OK: the Portal has no $id group, and its $next group stays"
    else
        echo "FAIL: the Portal still has its $id group, lost $next or does not parse"
    fi
}
