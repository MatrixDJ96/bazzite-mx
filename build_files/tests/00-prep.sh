#!/usr/bin/env bash
# The three base snapshots survive and clean-stage undid the dnf.conf change.
set -euo pipefail

snap=$BUILD_STATE/repos.base.sha256
if [ -s "$snap" ] && grep -q ' fedora.repo$' "$snap"; then
    echo "OK: base repo snapshot present ($(wc -l < "$snap") files)"
else
    echo "FAIL: base repo snapshot missing or without fedora.repo"
fi

snap=$BUILD_STATE/repos.base.enabled
if [ -s "$snap" ] && grep -qx fedora "$snap"; then
    echo "OK: base enabled-repository snapshot present ($(paste -sd ' ' "$snap"))"
else
    echo "FAIL: base enabled-repository snapshot missing or without fedora"
fi

if grep -q '^keepcache=0' /etc/dnf/dnf.conf && ! grep -q '^timeout=' /etc/dnf/dnf.conf; then
    echo "OK: dnf.conf restored to the base's values"
else
    echo "FAIL: dnf.conf still carries the build-time settings"
fi
