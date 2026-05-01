#!/usr/bin/bash
# DX smoke tests. Runs after the build orchestrator, immediately before
# bootc container lint. Bloccante: ogni assertion fa exit 1 sulla build.
#
# Phase 1 verifies only the DX overlay markers (sysctl + modules-load).
# Branding (kcm-about Variant=Developer Experience) is best-effort because
# Bazzite's KCM path differs from Aurora and will be wired in a later phase.
# Phase 2-9 will extend this file with rpm-q + systemctl is-enabled
# assertions for each new domain (container, virt, IDE, cockpit, CLI, extras).

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

# --- IP forwarding sysctl marker ---
if [ ! -f /etc/sysctl.d/90-bazzite-mx-dx-forwarding.conf ]; then
    echo "FAIL: missing /etc/sysctl.d/90-bazzite-mx-dx-forwarding.conf"
    exit 1
fi

# --- iptable_nat modules-load marker ---
if [ ! -f /etc/modules-load.d/90-bazzite-mx-dx.conf ]; then
    echo "FAIL: missing /etc/modules-load.d/90-bazzite-mx-dx.conf"
    exit 1
fi

echo "DX smoke tests OK."
echo "::endgroup::"
