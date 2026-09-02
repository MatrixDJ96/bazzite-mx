#!/usr/bin/env bash
# Smoke test of 20-setup-services.sh: the hook framework, its system unit,
# the dispatcher, and every shipped system-setup hook parsed with bash -n
# (a hook's syntax error would otherwise surface only in the journal).
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

LIBSETUP=/usr/lib/ublue/setup-services/libsetup.sh
DISPATCHER=/usr/libexec/ublue-system-setup
HOOKS=/usr/share/ublue-os/system-setup.hooks.d

check_dispatcher() {
    if [ -f "$LIBSETUP" ] && [ -x "$DISPATCHER" ]; then
        echo "OK: dispatcher and libsetup.sh present"
    else
        echo "FAIL: $DISPATCHER or libsetup.sh missing"
    fi
}

check_hooks_parse() {
    local hook parsed=0

    for hook in "$HOOKS"/*; do
        if [ ! -e "$hook" ]; then
            continue
        fi

        if [ -f "$hook" ] && bash -n "$hook"; then
            parsed=$((parsed + 1))
        else
            echo "FAIL: $hook is not a file bash can parse"
        fi
    done

    if [ "$parsed" -gt 0 ]; then
        echo "OK: $parsed system-setup hook(s) parse"
    else
        echo "FAIL: no system-setup hook under $HOOKS"
    fi
}

check_pkg ublue-setup-services
check_unit_state ublue-system-setup.service enabled
check_dispatcher
check_hooks_parse
