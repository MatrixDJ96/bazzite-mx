#!/usr/bin/bash
# MX block 21: hide the virt-manager flatpak from Discover/Bazaar.
#
# Companion to 20-virtualization.sh (virt-manager comes from the Fedora
# repo as rpm). virt-manager is NOT in Bazzite's default-install list,
# so only the blocklist is patched, not the install list.
#
# Reference Bazzite files:
#  /usr/share/ublue-os/flatpak-blocklist         (Flathub remote filter)

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

# shellcheck disable=SC1091
source /ctx/build_files/shared/writeback-helpers.sh

BLOCKLIST=/usr/share/ublue-os/flatpak-blocklist

### Extend flatpak-blocklist with virt-manager ###
# Idempotent: append only if the line isn't already there. We extend
# instead of replacing so we don't drop upstream entries (Steam,
# Lutris, Firefox-from-62-firefox-flatpak-exclude.sh, ...).
if [ ! -f "$BLOCKLIST" ]; then
    echo "FAIL: $BLOCKLIST not found (did Bazzite change layout?)"
    exit 1
fi
grep -q '^deny org\.virt_manager\.virt-manager/\*$' "$BLOCKLIST" \
    || echo "deny org.virt_manager.virt-manager/*" >> "$BLOCKLIST"

# The append lands in place on a base-image file, the shape that shipped the
# master justfile with a NUL tail in 44.20260826 (gotcha #34): rewrite the
# blocklist onto a fresh inode so the appended line survives the layer commit.
rewrite_fresh_inode "$BLOCKLIST"

echo "::endgroup::"
