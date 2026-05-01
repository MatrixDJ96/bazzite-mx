#!/usr/bin/bash
# DX smoke tests. Runs as the very last build step, after bootc lint,
# only when IMAGE_TIER=dx. Bloccante: ogni assertion fa exit 1 sulla build.
#
# Phase 1 verifies only the branding marker.
# Phase 2-9 will extend this file with rpm-q + systemctl is-enabled assertions
# for each new domain (container, virt, IDE, cockpit, CLI, extras).

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

# --- Branding ---
EXPECTED_VARIANT="Developer Experience"
KCM=/usr/share/kcm-about-distro/kcm-about-distrorc
ACTUAL=$(grep '^Variant=' "$KCM" 2>/dev/null | cut -d= -f2- || true)

if [ "$ACTUAL" != "$EXPECTED_VARIANT" ]; then
    echo "FAIL: expected Variant=$EXPECTED_VARIANT, got '$ACTUAL'"
    exit 1
fi

# --- IP forwarding sysctl ---
if [ ! -f /etc/sysctl.d/90-bazzite-mx-dx-forwarding.conf ]; then
    echo "FAIL: missing /etc/sysctl.d/90-bazzite-mx-dx-forwarding.conf"
    exit 1
fi
if [ ! -f /etc/modules-load.d/90-bazzite-mx-dx.conf ]; then
    echo "FAIL: missing /etc/modules-load.d/90-bazzite-mx-dx.conf"
    exit 1
fi

echo "DX smoke tests OK."
echo "::endgroup::"
