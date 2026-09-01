#!/usr/bin/bash
# MX block 62: exclude the Firefox flatpak from Bazzite's default-install
# and hide it from Discover/Bazaar (companion to 61-firefox-rpm.sh).
#
# Drift-tolerant: patch the Bazzite files in place at build time rather
# than overriding them with static copies.
#
# Reference Bazzite files:
#  /usr/share/ublue-os/bazzite/flatpak/install   (default-install list)
#  /usr/share/ublue-os/flatpak-blocklist         (Flathub remote filter)

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

# shellcheck disable=SC1091
source /ctx/build_files/shared/writeback-helpers.sh

INSTALL_LIST=/usr/share/ublue-os/bazzite/flatpak/install
BLOCKLIST=/usr/share/ublue-os/flatpak-blocklist

### Section 1: remove org.mozilla.firefox from the default-install list ###
# This list has NO executable consumer in the shipped image: nothing under
# /usr/bin, /usr/libexec or /usr/lib/systemd reads it (MEASURED 2026-09-01 on
# the preflight image -- the only hits are the installation-guide HTML pages),
# and bazzite-flatpak-manager v35 reads the blocklist alone. The list is the
# ISO/installer path's default set, so the sed stays for images built into
# media; the LIVE defence on a running host is Section 2.
# File sanity check: must exist (fail-fast if Bazzite renames the path
# in the future instead of silent no-op).
if [ ! -f "$INSTALL_LIST" ]; then
    echo "FAIL: $INSTALL_LIST not found (did Bazzite change layout?)"
    exit 1
fi
sed -i '/^org\.mozilla\.firefox$/d' "$INSTALL_LIST"

### Section 2: extend flatpak-blocklist with Firefox ###
# The live defence: bazzite-flatpak-manager passes this file to
# `flatpak remote-modify --system --filter=... flathub`, so a denied ref cannot
# be installed or even shown by Discover/Bazaar.
# Idempotent: append only if the line isn't already there. We extend
# instead of replacing so we don't drop upstream entries (Steam,
# Lutris, future additions).
if [ ! -f "$BLOCKLIST" ]; then
    echo "FAIL: $BLOCKLIST not found (did Bazzite change layout?)"
    exit 1
fi
grep -q '^deny org\.mozilla\.firefox/\*$' "$BLOCKLIST" \
    || echo "deny org.mozilla.firefox/*" >> "$BLOCKLIST"

# The append lands in place on a base-image file (gotcha #34), so the blocklist
# is rewritten onto a fresh inode. Section 1 needs no rewrite: `sed -i` writes a
# temporary and renames it, already a fresh inode (idiom table:
# docs/conventions.md § Writing base-image files).
rewrite_fresh_inode "$BLOCKLIST"

echo "::endgroup::"
