#!/usr/bin/bash
# MX block 48: hide the virt-manager flatpak from Discover/Bazaar.
#
# Companion to 20-virtualization.sh: now that virt-manager comes from
# the Fedora repo as rpm AND we override Bazzite's setup-virtualization
# recipe to drop the `flatpak install ...virt-manager` path, we want
# Discover/Bazaar to stop offering the flatpak as an "alternative" so
# users don't end up with a duplicate (and partially-broken) install.
#
# Note: unlike the Firefox case, virt-manager is NOT in Bazzite's
# default-install list (verified 2026-05-03 against
# system_files/desktop/kinoite/usr/share/ublue-os/bazzite/flatpak/install
# in the Bazzite repo) — so we only patch the blocklist, not the
# install list. Defense-in-depth: should Bazzite ever add it to the
# default-install list, the blocklist still hides it; we'd just need
# to add a sed line here at that point.
#
# Reference Bazzite files:
#  /usr/share/ublue-os/flatpak-blocklist         (Flathub remote filter)

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

BLOCKLIST=/usr/share/ublue-os/flatpak-blocklist

### Extend flatpak-blocklist with virt-manager ###
# Idempotent: append only if the line isn't already there. We extend
# instead of replacing so we don't drop upstream entries (Steam,
# Lutris, Firefox-from-46-firefox-flatpak-exclude.sh, ...).
if [ ! -f "$BLOCKLIST" ]; then
    echo "FAIL: $BLOCKLIST not found (did Bazzite change layout?)"
    exit 1
fi
grep -q '^deny org\.virt_manager\.virt-manager/\*$' "$BLOCKLIST" \
    || echo "deny org.virt_manager.virt-manager/*" >> "$BLOCKLIST"

echo "::endgroup::"
