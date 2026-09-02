#!/usr/bin/env bash
# The base's Flatpak filter. bazzite-flatpak-manager passes the blocklist to
# `flatpak remote-modify --filter` on Flathub at every boot, so a `deny <ref>`
# line keeps the Flatpak twin of a shipped RPM out of Discover and Bazaar.
# Sourced by lib/env.sh.

FLATPAK_BLOCKLIST=/usr/share/ublue-os/flatpak-blocklist

# `deny <ref>` appended once, after the base's lines, on a fresh inode; the
# line count and the uniqueness are asserted.
deny_flatpak() {
    local deny="deny $1" base_lines

    if [ ! -f "$FLATPAK_BLOCKLIST" ]; then
        fail_build "$FLATPAK_BLOCKLIST missing: Bazzite moved its Flatpak filter"
    fi

    if grep -qxF "$deny" "$FLATPAK_BLOCKLIST"; then
        log "flatpak: $FLATPAK_BLOCKLIST already has '$deny'"
    else
        # grep -c '' counts a last line without newline too; awk 1 terminates it.
        base_lines=$(grep -c '' "$FLATPAK_BLOCKLIST")
        {
            awk 1 "$FLATPAK_BLOCKLIST"
            echo "$deny"
        } > "$FLATPAK_BLOCKLIST.new"
        mv -f "$FLATPAK_BLOCKLIST.new" "$FLATPAK_BLOCKLIST"

        if [ "$(grep -c '' "$FLATPAK_BLOCKLIST")" -ne $((base_lines + 1)) ]; then
            fail_build "$FLATPAK_BLOCKLIST: $base_lines line(s) expected plus ours"
        fi
    fi

    if [ "$(grep -cxF "$deny" "$FLATPAK_BLOCKLIST")" -ne 1 ]; then
        fail_build "$FLATPAK_BLOCKLIST: '$deny' must appear once"
    fi
}
