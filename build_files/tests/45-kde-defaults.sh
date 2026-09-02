#!/usr/bin/env bash
# Smoke test of 45-kde-defaults.sh: the two Plasma update scripts with their
# guards, the Konsole and PowerShell skel files, and the user hook that seeds
# them (exercised on a fixture home); tests/70-justfile.sh owns the
# setup-panels recipe. A build has no plasmashell, so the scripts' effect on
# a session is proven on a host.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

UPDATES=/usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates
PANELS_SCRIPT=$UPDATES/bazzite-mx-panels.js
CLOCK_SCRIPT=$UPDATES/bazzite-mx-clock-seconds.js
SESSIONUI=/etc/skel/.local/share/kxmlgui5/konsole/sessionui.rc
POWERSHELL_PROFILE=/etc/skel/.config/powershell/profile.ps1
COPY_PASTE_HOOK=/usr/share/ublue-os/user-setup.hooks.d/12-bazzite-mx-copy-paste.sh

# --- the Plasma update scripts ------------------------------------------------

check_base_update_scripts() {
    if [ -f "$UPDATES/bazzite-pins.js" ]; then
        echo "OK: Bazzite's bazzite-pins.js is still there"
    else
        echo "FAIL: base update scripts missing from $UPDATES"
    fi
}

# skips_on <script> <if line>: the line is in the script and the next one is
# `continue;`, so a guard whose body went away reads as lost.
skips_on() {
    local script=$1 condition=$2 next

    next=$(grep -F -A1 -- "$condition" "$script" 2> /dev/null | tail -n1 | tr -d ' ' || true)
    [ "$next" = 'continue;' ]
}

check_update_scripts_guards() {
    local lost=() lost_names

    # On an existing layout a panel's screen reads -1 until it has a view.
    if ! skips_on "$PANELS_SCRIPT" 'if (panels().some(p => screenOf(p) === s)) {' \
        || grep -qF 'p.screen ===' "$PANELS_SCRIPT" 2> /dev/null \
        || ! grep -qF 'return Number(panel.readConfig("lastScreen", -1));' "$PANELS_SCRIPT" \
            2> /dev/null; then
        lost+=('the screen check')
    fi

    if ! skips_on "$PANELS_SCRIPT" 'if (type === "org.kde.plasma.systemtray") {'; then
        lost+=('the systemtray exclusion')
    fi

    if ! grep -qF 'widget.writeConfig("showOnlyCurrentScreen", true);' "$PANELS_SCRIPT" \
        2> /dev/null; then
        lost+=('showOnlyCurrentScreen')
    fi

    if [ ${#lost[@]} -eq 0 ]; then
        echo "OK: panels script: screen check, no system tray, per-screen tasks"
    else
        lost_names=$(printf '%s\n' "${lost[@]}" | on_one_line none ',' || true)
        echo "FAIL: panels script lost ${#lost[@]} guard(s): $lost_names"
    fi

    # The settings dialog writes the name, which a numeric read takes for 1.
    if grep -qF 'String(widget.readConfig("showSeconds", "1")).toLowerCase();' "$CLOCK_SCRIPT" \
        2> /dev/null \
        && grep -qF 'if (current === "1" || current === "tooltip") {' "$CLOCK_SCRIPT" \
            2> /dev/null; then
        echo "OK: clock script changes only the upstream default"
    else
        echo "FAIL: clock script no longer checks the current value"
    fi
}

# --- the skel files -----------------------------------------------------------

check_konsole_shortcuts() {
    local copy_action='<Action name="edit_copy" shortcut="Ctrl+C; Ctrl+Shift+C"/>'

    if [ -f "$SESSIONUI" ] && xmllint --noout "$SESSIONUI" 2> /dev/null \
        && grep -q '<gui name="session" version="1">' "$SESSIONUI" 2> /dev/null \
        && grep -q "$copy_action" "$SESSIONUI" 2> /dev/null; then
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
    if [ -s "$POWERSHELL_PROFILE" ] \
        && grep -q 'CopyOrCancelLine' "$POWERSHELL_PROFILE" 2> /dev/null \
        && grep -q 'wl-paste' "$POWERSHELL_PROFILE" 2> /dev/null; then
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

# --- the hook that seeds the skel files ---------------------------------------

run_copy_paste_hook() {
    local home=$1

    HOME=$home bash "$COPY_PASTE_HOOK" 2>&1
}

# An account without the two files gets the skel copies, byte for byte.
check_hook_seeds_missing_files() {
    local home=$1
    local output

    if output=$(run_copy_paste_hook "$home") \
        && cmp -s "$SESSIONUI" "$home/.local/share/kxmlgui5/konsole/sessionui.rc" \
        && cmp -s "$POWERSHELL_PROFILE" "$home/.config/powershell/profile.ps1" \
        && grep -q '2 file(s) seeded, 2 present' <<< "$output"; then
        echo "OK: hook seeds the Konsole shortcuts and the PowerShell profile from skel"
    else
        echo "FAIL: hook on an empty home: $(on_one_line 'no output' <<< "$output")"
    fi
}

# A file the user already has is theirs: the second run changes nothing.
check_hook_keeps_user_files() {
    local home=$1
    local output

    mkdir -p "$home/.config/powershell"
    echo 'user edit' > "$home/.config/powershell/profile.ps1"

    if output=$(run_copy_paste_hook "$home") \
        && [ "$(cat "$home/.config/powershell/profile.ps1")" = 'user edit' ] \
        && grep -q '0 file(s) seeded, 2 present' <<< "$output"; then
        echo "OK: hook leaves a file the user already has alone"
    else
        echo "FAIL: second hook run: $(on_one_line 'no output' <<< "$output")"
    fi
}

# Known-bad: the target directories cannot be created. A regular file in
# their place refuses mkdir for root as well, and the build runs the tests
# as root.
check_hook_fails_when_directories_cannot_be_created() {
    local home=$1
    local output

    mkdir -p "$home"
    touch "$home/.local" "$home/.config"

    if output=$(run_copy_paste_hook "$home"); then
        echo "FAIL: hook exited 0 with the target directories blocked"
    elif grep -q 'ERROR: could not seed' <<< "$output"; then
        echo "OK: hook reports and fails when a copy fails"
    else
        echo "FAIL: hook failed without naming the files: $(on_one_line 'no output' <<< "$output")"
    fi
}

check_copy_paste_hook() {
    local fixture

    fixture=$(mktemp -d)
    mkdir -p "$fixture/home"
    check_hook_seeds_missing_files "$fixture/home"
    check_hook_keeps_user_files "$fixture/home"
    check_hook_fails_when_directories_cannot_be_created "$fixture/locked"
    rm -rf "$fixture"
}

# --- main ---------------------------------------------------------------------

check_base_update_scripts
check_update_scripts_guards
check_konsole_shortcuts
check_powershell_profile
check_copy_paste_hook
