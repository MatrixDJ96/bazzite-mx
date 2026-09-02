#!/usr/bin/env bash
# Smoke test of 80-fix-opt.sh: nothing under /var/opt, every tmpfiles line
# applied on a fixture root, and 1Password's binaries with the modes and
# groups its %post set.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

FIX_OPT=$(dirname "$(realpath "$0")")/../80-fix-opt.sh
CONF=/usr/lib/tmpfiles.d/bazzite-mx-opt.conf
OPT=/usr/lib/opt/1Password

# --- the relocation -----------------------------------------------------------

check_self_test() {
    if bash "$FIX_OPT" --self-test > /dev/null; then
        echo "OK: fix-opt self-test refuses the known-bad layouts"
    else
        echo "FAIL: fix-opt self-test"
    fi
}

check_var_opt_empty() {
    if [ -z "$(ls -A /var/opt 2> /dev/null)" ]; then
        echo "OK: /var/opt empty in the image"
    else
        echo "FAIL: /var/opt holds $(ls -A /var/opt | tr '\n' ' ')"
    fi
}

check_tmpfiles_lines() {
    local onepassword_line='^L+ /var/opt/1Password - - - - /usr/lib/opt/1Password$'
    local link_rule='^L\+ /var/opt/[^ /]+ - - - - /usr/lib/opt/[^ /]+$'
    local not_a_rule link target applied=0

    if [ -s "$CONF" ] && grep -q "$onepassword_line" "$CONF"; then
        echo "OK: $CONF links /var/opt/1Password to /usr/lib/opt/1Password"
    else
        echo "FAIL: $CONF: $(cat "$CONF" 2>&1 | tr '\n' ';')"
    fi

    not_a_rule=$(grep -vE "$link_rule" "$CONF" | head -n1 || true)
    if [ -z "$not_a_rule" ]; then
        echo "OK: every line of $CONF is an L+ rule"
    else
        echo "FAIL: $CONF has a line that is not an L+ rule: $not_a_rule"
    fi

    while read -r _ link _ _ _ _ target; do
        if [ -d "$target" ] && [ "$(basename "$link")" = "$(basename "$target")" ]; then
            applied=$((applied + 1))
        else
            echo "FAIL: $CONF: $link -> $target, target missing or names differ"
        fi
    done < "$CONF"
    if [ "$applied" -gt 0 ]; then
        echo "OK: $applied tmpfiles target(s) exist under /usr/lib/opt"
    else
        echo "FAIL: $CONF applies no tmpfiles rule"
    fi
}

# systemd-tmpfiles creates the links a host gets at boot, so the file is
# proven to parse and to do what it says.
check_tmpfiles_on_fixture_root() {
    local fixture link

    fixture=$(mktemp -d)
    mkdir -p "$fixture/var/opt"

    if systemd-tmpfiles --root="$fixture" --create "$CONF" 2> "$fixture/err" \
        && [ "$(readlink "$fixture/var/opt/1Password")" = /usr/lib/opt/1Password ]; then
        echo "OK: systemd-tmpfiles applies $CONF on a fixture root"
    else
        link=$(readlink "$fixture/var/opt/1Password" 2>&1 || true)
        echo "FAIL: systemd-tmpfiles on a fixture root: $(cat "$fixture/err") link=$link"
    fi

    rm -rf "$fixture"
}

# --- 1Password's binaries -----------------------------------------------------

gid_of() {
    local group=$1

    awk -F: -v g="$group" '$1 == g { print $3 }' /usr/lib/group
}

# What 1Password's %post sets: chrome-sandbox setuid root, the browser
# helper and the MCP server setgid to their groups, the gid read from
# /usr/lib/group.
check_onepassword_modes() {
    local mode pair binary group gid mode_and_gid alias_target

    if [ -x "$OPT/1password" ] && [ -f "$OPT/com.1password.1Password.policy.tpl" ]; then
        echo "OK: $OPT holds the application"
    else
        echo "FAIL: $OPT incomplete: $(ls "$OPT" 2>&1 | head -n3 | tr '\n' ' ')"
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
        gid=$(gid_of "$group")
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
        echo "FAIL: onepassword-mcp alias: $(readlink "$OPT/onepassword-mcp" 2>&1 || echo missing)"
    fi
}

# --- main ---------------------------------------------------------------------

check_self_test
check_var_opt_empty
check_tmpfiles_lines
check_tmpfiles_on_fixture_root
check_onepassword_modes
