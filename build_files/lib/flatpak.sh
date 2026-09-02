#!/usr/bin/env bash
# The base's Flatpak filter. bazzite-flatpak-manager sets the blocklist as
# Flathub's filter (`flatpak remote-modify --filter`) when its version or the
# image name changes, and the remote keeps the file's path, so a `deny <ref>`
# line keeps the Flatpak twin of a shipped RPM out of Discover and Bazaar.
# Sourced by lib/env.sh.

FLATPAK_BLOCKLIST=/usr/share/ublue-os/flatpak-blocklist

# `deny <ref>` appended once, after the base's lines, on a fresh inode; the
# uniqueness is asserted.
deny_flatpak() {
    local deny="deny $1"

    if [ ! -f "$FLATPAK_BLOCKLIST" ]; then
        fail_build "$FLATPAK_BLOCKLIST missing: Bazzite moved its Flatpak filter"
    fi

    {
        awk 1 "$FLATPAK_BLOCKLIST"
        echo "$deny"
    } > "$FLATPAK_BLOCKLIST.new"
    mv -f "$FLATPAK_BLOCKLIST.new" "$FLATPAK_BLOCKLIST"

    if [ "$(grep -cxF "$deny" "$FLATPAK_BLOCKLIST")" -ne 1 ]; then
        fail_build "$FLATPAK_BLOCKLIST: '$deny' must appear once"
    fi
}
