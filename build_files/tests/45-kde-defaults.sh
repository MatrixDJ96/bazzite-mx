#!/usr/bin/env bash
# Smoke test of 45-kde-defaults.sh: the two Plasma update scripts with their
# guards, the Konsole and PowerShell skel files, and the setup-panels recipe.
# A build has no plasmashell, so the scripts' effect on a session is proven
# on a host.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
UPDATES=/usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates
PANELS_SCRIPT=$UPDATES/bazzite-mx-panels.js
CLOCK_SCRIPT=$UPDATES/bazzite-mx-clock-seconds.js
SESSIONUI=/etc/skel/.local/share/kxmlgui5/konsole/sessionui.rc
POWERSHELL_PROFILE=/etc/skel/.config/powershell/profile.ps1
RECIPES=/usr/share/ublue-os/just/95-bazzite-mx.just

# --- the Plasma update scripts ------------------------------------------------

check_update_scripts_shipped() {
    local script

    for script in bazzite-mx-clock-seconds.js bazzite-mx-panels.js; do
        if cmp -s "$CTX/system_files$UPDATES/$script" "$UPDATES/$script"; then
            echo "OK: $UPDATES/$script is the vendored copy"
        else
            echo "FAIL: $UPDATES/$script missing or not the vendored copy"
        fi
    done

    if [ -f "$UPDATES/bazzite-pins.js" ] && [ -f "$UPDATES/00-start-here-2.js" ]; then
        echo "OK: the base's update scripts are still there (bazzite-pins.js, 00-start-here-2.js)"
    else
        echo "FAIL: base update scripts missing from $UPDATES"
    fi
}

# Plasma runs the scripts in file-name order, and the panels script sets
# seconds on the clocks it creates.
check_update_scripts_order() {
    local first

    first=$(find "$UPDATES" -maxdepth 1 -name 'bazzite-mx-*.js' -printf '%f\n' | sort | head -n1)
    if [ "$first" = "bazzite-mx-clock-seconds.js" ]; then
        echo "OK: bazzite-mx-clock-seconds.js sorts before bazzite-mx-panels.js"
    else
        echo "FAIL: update script order: first is $first"
    fi
}

check_update_scripts_guards() {
    local lost_guard="screen check, systemtray exclusion or showOnlyCurrentScreen"

    if grep -q 'panels().some(p => p.screen === s)' "$PANELS_SCRIPT" \
        && grep -q '"org.kde.plasma.systemtray"' "$PANELS_SCRIPT" \
        && grep -q 'showOnlyCurrentScreen' "$PANELS_SCRIPT"; then
        echo "OK: panels script: screen check, no system tray, per-screen tasks"
    else
        echo "FAIL: panels script lost a guard ($lost_guard)"
    fi

    if grep -q 'readConfig("showSeconds", 1) == 1' "$CLOCK_SCRIPT"; then
        echo "OK: clock script changes only the upstream default"
    else
        echo "FAIL: clock script no longer checks the current value"
    fi
}

# --- the skel files -----------------------------------------------------------

check_konsole_shortcuts() {
    local copy_action='<Action name="edit_copy" shortcut="Ctrl+C; Ctrl+Shift+C"/>'

    if [ -f "$SESSIONUI" ] && xmllint --noout "$SESSIONUI" 2> /dev/null \
        && grep -q '<gui name="session" version="1">' "$SESSIONUI" \
        && grep -q "$copy_action" "$SESSIONUI"; then
        echo "OK: skel Konsole sessionui.rc: version 1, edit_copy on Ctrl+C"
    else
        echo "FAIL: $SESSIONUI missing, malformed, or changed"
    fi

    if rpm -q konsole > /dev/null; then
        echo "OK: konsole $(rpm -q --qf '%{VERSION}' konsole) in the image"
    else
        echo "FAIL: konsole missing"
    fi
}

check_powershell_profile() {
    if [ -s "$POWERSHELL_PROFILE" ] && grep -q 'CopyOrCancelLine' "$POWERSHELL_PROFILE" \
        && grep -q 'wl-paste' "$POWERSHELL_PROFILE"; then
        echo "OK: skel PowerShell profile carries the Ctrl+C/Ctrl+V handlers"
    else
        echo "FAIL: $POWERSHELL_PROFILE missing or lost the handlers"
    fi

    if [ -x /usr/bin/wl-copy ] && [ -x /usr/bin/wl-paste ]; then
        echo "OK: wl-copy and wl-paste in the image ($(rpm -q --qf '%{VERSION}' wl-clipboard))"
    else
        echo "FAIL: wl-clipboard binaries missing"
    fi
}

# --- the recipe ---------------------------------------------------------------

check_recipe() {
    if cmp -s "$CTX/system_files$RECIPES" "$RECIPES"; then
        echo "OK: $RECIPES is the vendored copy"
    else
        echo "FAIL: $RECIPES missing or not the vendored copy"
    fi

    if has_recipe "$RECIPES" setup-panels; then
        echo "OK: recipe file defines setup-panels"
    else
        echo "FAIL: recipe summary: $(just --justfile "$RECIPES" --summary 2>&1)"
    fi

    check_just_fmt "$RECIPES"
    check_recipe_help "$RECIPES" setup-panels
}

# --- main ---------------------------------------------------------------------

check_update_scripts_shipped
check_update_scripts_order
check_update_scripts_guards
check_konsole_shortcuts
check_powershell_profile
check_recipe
