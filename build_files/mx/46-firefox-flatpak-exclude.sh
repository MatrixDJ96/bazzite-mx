#!/usr/bin/bash
# MX block 46: exclude the Firefox flatpak from Bazzite's default-install
# and hide it from Discover/Bazaar.
#
# Companion to 45-firefox-rpm.sh: now that Firefox comes from the
# Mozilla repo as rpm, we need to prevent bazzite-flatpak-manager from
# also installing the flatpak version on first boot, and we want
# Discover/Bazaar to stop suggesting the flatpak as an "alternative".
#
# Drift-tolerant strategy: instead of overriding the Bazzite files with
# our own static versions (which would be out-of-date at the first
# upstream upgrade), we patch the files in place at build time:
#  - sed: removes the org.mozilla.firefox line from the install list
#  - grep || echo: appends `deny org.mozilla.firefox/*` to the
#    blocklist only if not already present (idempotent)
#
# Reference Bazzite files:
#  /usr/share/ublue-os/bazzite/flatpak/install   (default-install list)
#  /usr/share/ublue-os/flatpak-blocklist         (Flathub remote filter)

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

INSTALL_LIST=/usr/share/ublue-os/bazzite/flatpak/install
BLOCKLIST=/usr/share/ublue-os/flatpak-blocklist

### Section 1: remove org.mozilla.firefox from the default-install list ###
# File sanity check: must exist (fail-fast if Bazzite renames the path
# in the future instead of silent no-op).
if [ ! -f "$INSTALL_LIST" ]; then
    echo "FAIL: $INSTALL_LIST not found (did Bazzite change layout?)"
    exit 1
fi
sed -i '/^org\.mozilla\.firefox$/d' "$INSTALL_LIST"

### Section 2: extend flatpak-blocklist with Firefox ###
# Idempotent: append only if the line isn't already there. We extend
# instead of replacing so we don't drop upstream entries (Steam,
# Lutris, future additions).
if [ ! -f "$BLOCKLIST" ]; then
    echo "FAIL: $BLOCKLIST not found (did Bazzite change layout?)"
    exit 1
fi
grep -q '^deny org\.mozilla\.firefox/\*$' "$BLOCKLIST" \
    || echo "deny org.mozilla.firefox/*" >> "$BLOCKLIST"

echo "::endgroup::"
