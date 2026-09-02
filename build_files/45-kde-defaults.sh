#!/usr/bin/env bash
# KDE defaults: seconds on the panel clock, a panel on every screen, Windows
# style copy and paste in Konsole and PowerShell. They ship as Plasma update
# scripts and skel files, so this script only asserts they landed.
#
# Usage: run by build.sh; no arguments.
# Writes: nothing; every file comes from system_files/.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

UPDATES=/usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates
SESSIONUI=/etc/skel/.local/share/kxmlgui5/konsole/sessionui.rc
PROFILE=/etc/skel/.config/powershell/profile.ps1
RECIPES=/usr/share/ublue-os/just/95-bazzite-mx.just

# --- the checks ---------------------------------------------------------------

# Bazzite's own update script proves the directory is where Plasma reads
# update scripts from, before ours are looked for.
require_update_scripts() {
    local script

    if [ ! -d "$UPDATES" ]; then
        fail_build "$UPDATES missing: plasma-workspace changed its shell package layout"
    fi

    if [ ! -f "$UPDATES/bazzite-pins.js" ]; then
        fail_build "$UPDATES/bazzite-pins.js missing: Bazzite no longer ships update scripts here"
    fi

    for script in bazzite-mx-clock-seconds.js bazzite-mx-panels.js; do
        if [ ! -s "$UPDATES/$script" ]; then
            fail_build "$UPDATES/$script missing"
        fi
    done
}

# The kxmlgui file merges into Konsole's own only at version 1; a higher
# version replaces the whole session menu.
require_konsole_shortcuts() {
    if [ ! -f "$SESSIONUI" ]; then
        fail_build "$SESSIONUI missing"
    fi

    if ! xmllint --noout "$SESSIONUI"; then
        fail_build "$SESSIONUI is not well-formed XML"
    fi

    if ! grep -q '<gui name="session" version="1">' "$SESSIONUI"; then
        fail_build "$SESSIONUI: version must stay 1 (merge, not replace)"
    fi

    if ! rpm -q konsole > /dev/null; then
        fail_build "konsole not in the base"
    fi
}

require_powershell_profile() {
    if [ ! -s "$PROFILE" ]; then
        fail_build "$PROFILE missing"
    fi

    if ! rpm -q wl-clipboard > /dev/null; then
        fail_build "wl-clipboard not in the base: the PowerShell handlers need wl-copy/wl-paste"
    fi
}

require_recipe() {
    if [ ! -f "$RECIPES" ]; then
        fail_build "$RECIPES missing"
    fi

    if ! has_recipe "$RECIPES" setup-panels; then
        fail_build "$RECIPES does not define setup-panels"
    fi
}

# --- main ---------------------------------------------------------------------

require_update_scripts
require_konsole_shortcuts
require_powershell_profile
require_recipe

plasma_version=$(rpm -q --qf '%{VERSION}' plasma-workspace)
log "kde-defaults: 2 update scripts, Konsole and PowerShell skel files, setup-panels recipe" \
    "(plasma-workspace $plasma_version)"
