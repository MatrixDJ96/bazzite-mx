#!/usr/bin/bash
# MX block 46: exclude the Firefox flatpak from Bazzite's default-install
# and hide it from Discover/Bazaar (companion to 45-firefox-rpm.sh).
#
# Drift-tolerant: patch the Bazzite files in place at build time rather
# than overriding them with static copies:
#  - sed: removes the org.mozilla.firefox line from the install list
#  - grep || echo: idempotently appends `deny org.mozilla.firefox/*`
#    to the blocklist
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
