#!/usr/bin/bash
# MX smoke tests. Runs after the build orchestrator, immediately before
# bootc container lint. Blocking: every assertion exits 1 on failure.
#
# Each domain script in build_files/mx/ extends this file with rpm-q +
# systemctl is-enabled + file-existence assertions for the things it
# adds, so the test grows in parallel with the build.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

# --- IP forwarding sysctl marker ---
if [ ! -f /etc/sysctl.d/90-bazzite-mx-forwarding.conf ]; then
    echo "FAIL: missing /etc/sysctl.d/90-bazzite-mx-forwarding.conf"
    exit 1
fi

# --- iptable_nat modules-load marker ---
if [ ! -f /etc/modules-load.d/90-bazzite-mx.conf ]; then
    echo "FAIL: missing /etc/modules-load.d/90-bazzite-mx.conf"
    exit 1
fi

echo "MX smoke tests OK."
