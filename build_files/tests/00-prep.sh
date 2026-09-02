#!/usr/bin/env bash
# Smoke test of 00-prep.sh: 95-clean-stage.sh undid the dnf.conf change. What
# the snapshots 00-prep.sh records say is their readers' subject, and only
# there is it falsifiable: 90-validate-repos.sh for the repository ones.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

check_dnf_conf_restored() {
    if grep -q '^keepcache=0' /etc/dnf/dnf.conf 2> /dev/null \
        && ! grep -q '^timeout=' /etc/dnf/dnf.conf 2> /dev/null; then
        echo "OK: dnf.conf restored to the base's values"
    else
        echo "FAIL: dnf.conf still carries the build-time settings"
    fi
}

check_dnf_conf_restored
