#!/usr/bin/env bash
# Smoke test of 00-prep.sh: the three base snapshots survive in the image and
# 95-clean-stage.sh undid the dnf.conf change.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

REPO_SNAPSHOT=$BUILD_STATE/repos.base.sha256
ENABLED_SNAPSHOT=$BUILD_STATE/repos.base.enabled
RECIPE_SNAPSHOT=$BUILD_STATE/just.base.summary
RECIPE_LINE='^[0-9][0-9]-[a-z-]*\.just: '

check_repo_snapshot() {
    if [ -s "$REPO_SNAPSHOT" ] && grep -q ' fedora.repo$' "$REPO_SNAPSHOT"; then
        echo "OK: base repo snapshot present ($(wc -l < "$REPO_SNAPSHOT") files)"
    else
        echo "FAIL: base repo snapshot missing or without fedora.repo"
    fi
}

check_enabled_snapshot() {
    if [ -s "$ENABLED_SNAPSHOT" ] && grep -qx fedora "$ENABLED_SNAPSHOT"; then
        echo "OK: base enabled-repository snapshot present ($(paste -sd ' ' "$ENABLED_SNAPSHOT"))"
    else
        echo "FAIL: base enabled-repository snapshot missing or without fedora"
    fi
}

check_dnf_conf_restored() {
    if grep -q '^keepcache=0' /etc/dnf/dnf.conf && ! grep -q '^timeout=' /etc/dnf/dnf.conf; then
        echo "OK: dnf.conf restored to the base's values"
    else
        echo "FAIL: dnf.conf still carries the build-time settings"
    fi
}

# One line per base .just file; what it says about the replaced files is
# tests/70-justfile.sh's subject.
check_recipe_snapshot() {
    local malformed

    if [ -s "$RECIPE_SNAPSHOT" ] && ! grep -qv "$RECIPE_LINE" "$RECIPE_SNAPSHOT"; then
        echo "OK: base recipe snapshot present ($(wc -l < "$RECIPE_SNAPSHOT") files)"
    else
        malformed=$(grep -v "$RECIPE_LINE" "$RECIPE_SNAPSHOT" 2>&1 | head -n3 | tr '\n' ' ')
        echo "FAIL: base recipe snapshot missing or malformed: $malformed"
    fi
}

check_repo_snapshot
check_enabled_snapshot
check_dnf_conf_restored
check_recipe_snapshot
