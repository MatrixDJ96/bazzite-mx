#!/usr/bin/env bash
# Smoke test of 80-fix-opt.sh: every tmpfiles line pointing at a directory
# that is there, applied on a fixture root, and
# 1Password's binaries with the modes and groups its %post set. That /var/opt
# is gone is tests/95-clean-stage.sh's subject, which fails on the directory
# existing at all.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

FIX_OPT=$(dirname "$(realpath "$0")")/../80-fix-opt.sh
CONF=/usr/lib/tmpfiles.d/bazzite-mx-opt.conf
OPT=/usr/lib/opt/1Password

# --- the relocation -----------------------------------------------------------

check_tmpfiles_lines() {
    local rules link target

    rules=$(cat "$CONF" 2> /dev/null || true)

    while read -r _ link _ _ _ _ target; do
        if [ -z "$link" ]; then
            continue
        fi

        if [ -d "$target" ]; then
            echo "OK: $target is there for $link"
        else
            echo "FAIL: $CONF: $link -> $target, target missing"
        fi
    done <<< "$rules"
}

# systemd-tmpfiles creates the links a host gets at boot, so the file is
# proven to parse and to do what it says.
check_tmpfiles_on_fixture_root() {
    local fixture link

    fixture=$(mktemp -d)
    mkdir -p "$fixture/var/opt"

    if systemd-tmpfiles --root="$fixture" --create "$CONF" 2> "$fixture/err" \
        && [ "$(readlink "$fixture/var/opt/1Password" 2> /dev/null)" = \
            /usr/lib/opt/1Password ]; then
        echo "OK: systemd-tmpfiles applies $CONF on a fixture root"
    else
        link=$(readlink "$fixture/var/opt/1Password" 2>&1 || true)
        echo "FAIL: systemd-tmpfiles on a fixture root:" \
            "$(cat "$fixture/err" 2>&1 | on_one_line 'no error output') link=${link:-none}"
    fi

    rm -rf "$fixture"
}

# --- 1Password's binaries -----------------------------------------------------

gid_of() {
    local group=$1

    awk -F: -v g="$group" '$1 == g { print $3 }' /usr/lib/group 2> /dev/null
}

# What 1Password's %post sets: chrome-sandbox setuid root, the browser
# helper and the MCP server setgid to their groups, the gid read from
# /usr/lib/group.
check_onepassword_modes() {
    local mode pair binary group gid mode_and_gid alias_target entries

    if [ -x "$OPT/1password" ] && [ -f "$OPT/com.1password.1Password.policy.tpl" ]; then
        echo "OK: $OPT holds the application"
    else
        entries=$(ls "$OPT" 2>&1 | head -n3 | tr '\n' ' ' || true)
        echo "FAIL: $OPT incomplete: ${entries:-empty}"
    fi

    mode=$(stat -c '%a %u' "$OPT/chrome-sandbox" 2>&1 || true)

    if [ "$mode" = "4755 0" ]; then
        echo "OK: chrome-sandbox 4755 root"
    else
        echo "FAIL: chrome-sandbox: $mode"
    fi

    for pair in "1Password-BrowserSupport:onepassword" "1password-mcp:onepassword-mcp"; do
        binary=${pair%%:*}
        group=${pair##*:}
        gid=$(gid_of "$group" || true)
        mode_and_gid=$(stat -c '%a %g' "$OPT/$binary" 2>&1 || true)

        if [ -n "$gid" ] && [ "$mode_and_gid" = "2755 $gid" ]; then
            echo "OK: $binary setgid $group ($gid)"
        else
            echo "FAIL: $binary: mode/gid '$mode_and_gid', group $group gid '${gid:-none}'"
        fi
    done

    alias_target=$(readlink "$OPT/onepassword-mcp" 2> /dev/null || true)

    if [ "$alias_target" = /opt/1Password/1password-mcp ]; then
        echo "OK: onepassword-mcp alias points through /opt"
    else
        echo "FAIL: onepassword-mcp alias: ${alias_target:-missing}"
    fi
}

# --- main ---------------------------------------------------------------------

check_self_test fix-opt bash "$FIX_OPT"
check_tmpfiles_lines
check_tmpfiles_on_fixture_root
check_onepassword_modes
