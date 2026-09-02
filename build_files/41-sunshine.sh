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

    if [ ! -x /usr/bin/sunshine ]; then
        fail_build "/usr/bin/sunshine missing after install"
    fi
}

# <capabilities> is what getcap printed for the binary.
require_kms_capabilities() {
    local capabilities=$1

    if [[ $capabilities != *cap_sys_admin* || $capabilities != *cap_sys_nice* ]]; then
        fail_build "/usr/bin/sunshine lacks the KMS capabilities: '$capabilities'"
    fi
}

# The unit, the udev rule and the module list come with the package; the
# virtual-monitor helpers come from the base and the recipe calls them.
require_package_files() {
    local helper

    if [ ! -f "/usr/lib/systemd/user/$UNIT" ]; then
        fail_build "$UNIT missing"
    fi

    if [ ! -f /usr/lib/udev/rules.d/60-sunshine.rules ]; then
        fail_build "60-sunshine.rules missing"
    fi

    if [ ! -f /usr/lib/modules-load.d/60-sunshine.conf ]; then
        fail_build "60-sunshine.conf missing"
    fi

    for helper in sunshine-start-vmon sunshine-stop-vmon; do
        if [ ! -x "/usr/libexec/$helper" ]; then
            fail_build "/usr/libexec/$helper missing:" \
                "the base no longer ships the virtual-monitor helpers"
        fi
    done
}

# Fedora's user presets do not enable it: asserted rather than assumed.
disable_user_unit() {
    local state

    systemctl --global disable "$UNIT"
    state=$(systemctl --global is-enabled "$UNIT" 2> /dev/null || true)

    if [ "$state" != disabled ]; then
        fail_build "$UNIT is ${state:-without a state} for users (expected disabled)"
    fi
}

# The package's entry starts the unit with `systemctl start`, past the
# recipe's portal limit and credentials (docs/divergences.md § Sunshine): it
# runs the recipe in a terminal instead, and its action that runs sunshine
# directly goes; tests/41-sunshine.sh checks the result.
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
capabilities=$(getcap /usr/bin/sunshine)
require_kms_capabilities "$capabilities"
require_package_files
disable_user_unit
route_menu_entry
remove_portal_announcement
remove_portal_group sunshine

sunshine_version=$(rpm -q --qf '%{VERSION}' Sunshine)
log "sunshine: Sunshine $sunshine_version, $capabilities, $UNIT disabled for users"
