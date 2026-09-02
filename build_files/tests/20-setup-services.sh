#!/usr/bin/env bash
# The hook framework, its system unit, and every shipped hook parsed with
# bash -n: a hook's syntax error would surface only in the journal.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

check_pkg ublue-setup-services
check_unit_state ublue-system-setup.service enabled

if [ -f /usr/lib/ublue/setup-services/libsetup.sh ] && [ -x /usr/libexec/ublue-system-setup ]; then
    echo "OK: dispatcher and libsetup.sh present"
else
    echo "FAIL: /usr/libexec/ublue-system-setup or libsetup.sh missing"
fi

HOOKS=/usr/share/ublue-os/system-setup.hooks.d
n=0
for hook in "$HOOKS"/*; do
    [ -e "$hook" ] || continue
    if [ -f "$hook" ] && bash -n "$hook"; then
        n=$((n + 1))
    else
        echo "FAIL: $hook is not a file bash can parse"
    fi
done
if [ "$n" -gt 0 ]; then
    echo "OK: $n system-setup hook(s) parse"
else
    echo "FAIL: no system-setup hook under $HOOKS"
fi
