#!/usr/bin/env bash
# The error and privilege helpers msi-setup calls and the modules-load file
# it writes. Sourced by msi-setup, never run; the sourcing script sets
# its own `set` options.
#
# Output contract: `ERROR: <reason>` on stderr is what the recipes and the
# tests read.

# Written by bazzite-mx-msi-setup enable.
# shellcheck disable=SC2034  # read by the sourcing msi-setup
MSI_MODULES_LOAD=/etc/modules-load.d/bazzite-mx-msi.conf

# --- errors and privileges ----------------------------------------------------

print_error() {
    echo "ERROR: $*" >&2
}

# reason_on_one_line <text>: a tool's diagnostic on one line, a blank between
# items and none at either end, `no output` when the tool printed nothing.
# An `ERROR:` line carries the reason inside itself: a diagnostic left to the
# tool reaches the log as a second, unprefixed line.
reason_on_one_line() {
    local reason=${1//$'\n'/ }

    reason=$(sed 's/^ *//;s/ *$//' <<< "$reason" || true)
    echo "${reason:-no output}"
}

exit_with_error() {
    print_error "$@"
    exit 1
}

# require_root <action> <recipe>: the recipe runs the action through sudo.
require_root() {
    local action=$1
    local recipe=$2

    if [ "$(id -u)" -ne 0 ]; then
        exit_with_error "$action needs root (ujust $recipe runs it through sudo)"
    fi
}
