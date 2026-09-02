#!/usr/bin/env bash
# Smoke test of 41-sunshine.sh: Sunshine from the vendored COPR. The key, the
# KMS capabilities, the udev and modules-load files, the disabled user unit,
# the menu entry that runs the recipe, the base's helpers, the base's
# announcement and the Portal's Sunshine group removed, and the recipe that
# replaces Bazzite's.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

KEY=/etc/pki/rpm-gpg/RPM-GPG-KEY-copr-lizardbyte-stable
SUNSHINE_REPO=/etc/yum.repos.d/sunshine.repo
UNIT=app-dev.lizardbyte.app.Sunshine.service
UNIT_FILE=/usr/lib/systemd/user/$UNIT
UDEV_RULES=/usr/lib/udev/rules.d/60-sunshine.rules
MODULES_LOAD=/usr/lib/modules-load.d/60-sunshine.conf
ANNOUNCEMENTS=/usr/share/ublue-os/announcements
RECIPE=/usr/share/ublue-os/just/82-bazzite-sunshine.just
MENU_ENTRY=/usr/share/applications/dev.lizardbyte.app.Sunshine.desktop

# --- the package --------------------------------------------------------------

check_binary() {
    local capabilities home version

    capabilities=$(getcap /usr/bin/sunshine 2>&1 || true)

    if [[ $capabilities == *cap_sys_admin* && $capabilities == *cap_sys_nice* ]]; then
        echo "OK: /usr/bin/sunshine carries the KMS capabilities ($capabilities)"
    else
        echo "FAIL: /usr/bin/sunshine capabilities: '${capabilities:-none}'"
    fi

    # The binary creates $HOME/.config/sunshine before it prints anything,
    # --version included, and aborts when it cannot: the build's HOME is
    # /root, a link to a /var/roothome the image does not carry
    # (docs/gotchas.md § `sunshine --version` needs a home directory). A
    # booted host has a home; the test lends one.
    home=$(mktemp -d)
    version=$(HOME=$home sunshine --version 2>&1 || true)
    rm -rf "$home"

    if grep -q 'Sunshine version: ' <<< "$version"; then
        echo "OK: sunshine --version runs"
    else
        echo "FAIL: sunshine --version:" \
            "$(head -n1 <<< "$version" | on_one_line 'no output on either stream')"
    fi
}

# tests/01 and 90-validate-repos.sh refuse a copy that differs from the
# vendored one.
check_copr_repo() {
    check_key_fingerprint "$KEY"
    check_repo_reads_key "$SUNSHINE_REPO" "$KEY"

    if ! grep -q '^priority=' "$SUNSHINE_REPO" 2> /dev/null; then
        echo "OK: $SUNSHINE_REPO carries no priority"
    else
        echo "FAIL: $SUNSHINE_REPO: $(grep '^priority=' "$SUNSHINE_REPO")"
    fi

    check_rpm_key e4f68234 "lizardbyte/stable"
}

check_user_unit() {
    local unit_lines

    check_unit_state --global "$UNIT" disabled "opt-in through the recipe"

    if grep -q '^ExecStart=/usr/bin/sunshine$' "$UNIT_FILE" 2> /dev/null; then
        echo "OK: user unit runs /usr/bin/sunshine"
    else
        unit_lines=$(grep '^ExecStart=' "$UNIT_FILE" 2>&1 | tr '\n' ' ' || true)
        echo "FAIL: user unit: ${unit_lines:-no ExecStart line}"
    fi
}

check_device_files() {
    if grep -q 'KERNEL=="uinput".*GROUP="input"' "$UDEV_RULES" 2> /dev/null \
        && grep -qx 'uhid' "$MODULES_LOAD" 2> /dev/null; then
        echo "OK: uinput udev rule and uhid modules-load shipped"
    else
        echo "FAIL: 60-sunshine.rules or 60-sunshine.conf missing or changed"
    fi
}

check_base_files() {
    local helper announcements

    for helper in sunshine-start-vmon sunshine-stop-vmon; do
        if [ -x "/usr/libexec/$helper" ] && bash -n "/usr/libexec/$helper" 2> /dev/null; then
            echo "OK: base helper /usr/libexec/$helper present"
        else
            echo "FAIL: /usr/libexec/$helper missing or does not parse"
        fi
    done

    check_desktop_file /usr/share/applications/dev.lizardbyte.app.Sunshine.desktop

    # By content: a renamed announcement is one 41-sunshine.sh no longer removes.
    announcements=$(grep -rli sunshine "$ANNOUNCEMENTS" 2> /dev/null | on_one_line none || true)

    if [ "$announcements" = none ]; then
        echo "OK: no Sunshine announcement in $ANNOUNCEMENTS"
    else
        echo "FAIL: Sunshine announcement still shipped: $announcements"
    fi
}

# The one Exec runs the recipe in a terminal; nothing starts the unit or
# sunshine past it.
check_menu_entry() {
    local want="Exec=bash -c \"ujust setup-sunshine enable; read -rp 'Press Enter to close'\""
    local execs

    execs=$(grep '^Exec=' "$MENU_ENTRY" 2> /dev/null || true)

    if [ "$execs" = "$want" ] && grep -qx 'Terminal=true' "$MENU_ENTRY"; then
        echo "OK: the Sunshine menu entry runs ujust setup-sunshine enable in a terminal"
    else
        echo "FAIL: the Sunshine menu entry: $(on_one_line 'no Exec line' <<< "$execs")"
    fi
}

# --- main ---------------------------------------------------------------------

check_binary
check_copr_repo
check_user_unit
check_menu_entry
check_device_files
check_base_files
check_recipe_help "$RECIPE" setup-sunshine
check_portal_group_removed sunshine visual-studio-code-linux
