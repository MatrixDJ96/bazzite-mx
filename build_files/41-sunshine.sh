#!/usr/bin/env bash
# Sunshine, the Moonlight streaming host, as the COPR RPM: KMS capture needs
# file capabilities a Flatpak cannot carry. The user unit stays disabled for
# everyone and `ujust setup-sunshine` enables it per user.
#
# Usage: run by build.sh; no arguments.
# Writes: the Sunshine package; its user unit disabled --global; its menu
#   entry rewritten to run the recipe; Bazzite's Portal announcement about the
#   Homebrew Sunshine and the Portal's Sunshine group, whose update, uninstall
#   and enable-brew are Bazzite's options, removed.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

UNIT=app-dev.lizardbyte.app.Sunshine.service
ANNOUNCEMENT=/usr/share/ublue-os/announcements/sunshine-brew.msg.json
MENU_ENTRY=/usr/share/applications/dev.lizardbyte.app.Sunshine.desktop
MENU_EXEC="Exec=bash -c \"ujust setup-sunshine enable; read -rp 'Press Enter to close'\""

# --- the steps ----------------------------------------------------------------

install_sunshine() {
    assert_key_fingerprint /etc/pki/rpm-gpg/RPM-GPG-KEY-copr-lizardbyte-stable

    # The COPR names the package "Sunshine", capital S.
    install_from_repo copr:copr.fedorainfracloud.org:lizardbyte:stable Sunshine
}

disable_user_unit() {
    systemctl --global disable "$UNIT"
}

# The package's entry starts the unit with `systemctl start`, past the recipe's
# portal limit and credentials: it runs the recipe in a terminal instead, and
# its action that runs sunshine directly goes; tests/41-sunshine.sh checks the
# result.
route_menu_entry() {
    local rewritten

    rewritten=$(awk -v exec_line="$MENU_EXEC" '
        /^\[Desktop Action / { exit }
        /^Actions=/ { next }
        /^Exec=/ { print exec_line; print "Terminal=true"; next }
        { print }' "$MENU_ENTRY")

    printf '%s\n' "$rewritten" > "$MENU_ENTRY"
}

remove_portal_announcement() {
    if [ -f "$ANNOUNCEMENT" ]; then
        rm -f "$ANNOUNCEMENT"
        log "sunshine: removed Bazzite's Portal announcement $ANNOUNCEMENT"
    fi
}

# --- main ---------------------------------------------------------------------

install_sunshine
disable_user_unit
route_menu_entry
remove_portal_announcement
remove_portal_group sunshine

sunshine_version=$(rpm -q --qf '%{VERSION}' Sunshine)
log "sunshine: Sunshine $sunshine_version, $UNIT disabled for users"
