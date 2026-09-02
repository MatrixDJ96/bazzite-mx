#!/usr/bin/env bash
# Smoke test of 20-setup-services.sh: the hook framework, its system unit,
# the dispatcher, and the package's Secure Boot notice removed. The lint
# job's ShellCheck parses our system-setup hook, the only one shipped.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

LIBSETUP=/usr/lib/ublue/setup-services/libsetup.sh
DISPATCHER=/usr/libexec/ublue-system-setup

check_dispatcher() {
    if [ -f "$LIBSETUP" ] && [ -x "$DISPATCHER" ]; then
        echo "OK: dispatcher and libsetup.sh present"
    else
        echo "FAIL: $DISPATCHER or libsetup.sh missing"
    fi
}

# The package's own manifest names the notice's files under /etc, so the test
# does not take the list from the build script it checks.
check_sb_notice_removed() {
    local files file left=0

    files=$(rpm -ql ublue-setup-services | grep -E '^/etc/.*sb-?key' || true)

    if [ -z "$files" ]; then
        echo "FAIL: ublue-setup-services lists no sb-key file under /etc to check"
        return
    fi

    while read -r file; do
        if [ -e "$file" ]; then
            echo "FAIL: $file still shipped: the sb-key-notify entry fails at every login"
            left=1
        fi
    done <<< "$files"

    if [ "$left" -eq 0 ]; then
        echo "OK: the sb-key-notify login script and skel entry are removed"
    fi
}

check_pkg ublue-setup-services
check_unit_state ublue-system-setup.service enabled
check_dispatcher
check_sb_notice_removed
