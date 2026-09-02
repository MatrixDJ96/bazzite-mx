#!/usr/bin/env bash
# Smoke test of 41-sunshine.sh: Sunshine from the vendored COPR. The key, the
# KMS capabilities, the udev and modules-load files, the disabled user unit,
# the menu entry that runs the recipe, the base's helpers and announcement,
# and the recipe that replaces Bazzite's.
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
APPS_JSON=/usr/share/sunshine/apps.json
ANNOUNCEMENTS=/usr/share/ublue-os/announcements
RECIPE=/usr/share/ublue-os/just/82-bazzite-sunshine.just
MENU_ENTRY=/usr/share/applications/dev.lizardbyte.app.Sunshine.desktop

# --- the package --------------------------------------------------------------

check_binary() {
    local capabilities home version

    if rpm -q Sunshine > /dev/null && [ -x /usr/bin/sunshine ]; then
        echo "OK: Sunshine $(rpm -q --qf '%{VERSION}' Sunshine)"
    else
        echo "FAIL: Sunshine not installed"
    fi

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

    if grep -qi sunshine <<< "$version"; then
        echo "OK: sunshine --version runs"
    else
        echo "FAIL: sunshine --version:" \
            "$(head -n1 <<< "$version" | on_one_line 'no output on either stream')"
    fi
}

# The shipped key is the pinned one, the .repo reads it from the file and
# stays disabled without a priority, and dnf5 imported the key into the rpm
# keyring at install.
check_copr_repo() {
    local repo_lines

    check_key_fingerprint "$KEY"

    if grep -q "^gpgkey=file://$KEY$" "$SUNSHINE_REPO" 2> /dev/null \
        && grep -qx 'enabled=0' "$SUNSHINE_REPO" 2> /dev/null \
        && ! grep -q '^priority=' "$SUNSHINE_REPO" 2> /dev/null; then
        echo "OK: $SUNSHINE_REPO reads the vendored key, disabled, no priority"
    else
        repo_lines=$(grep -E '^(enabled|gpgkey|priority)=' "$SUNSHINE_REPO" 2>&1 \
            | tr '\n' ' ' || true)
        echo "FAIL: $SUNSHINE_REPO: ${repo_lines:-no enabled, gpgkey or priority line}"
    fi

    check_rpm_key e4f68234 "lizardbyte/stable"
}

check_user_unit() {
    local unit_lines

    check_unit_state --global "$UNIT" disabled "opt-in through the recipe"

    if grep -q '^Alias=sunshine.service$' "$UNIT_FILE" 2> /dev/null \
        && grep -q '^ExecStart=/usr/bin/sunshine$' "$UNIT_FILE" 2> /dev/null; then
        echo "OK: user unit runs /usr/bin/sunshine with the sunshine.service alias"
    else
        unit_lines=$(grep -E '^(Alias|ExecStart)=' "$UNIT_FILE" 2>&1 | tr '\n' ' ' || true)
        echo "FAIL: user unit: ${unit_lines:-no Alias or ExecStart line}"
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

    if [ -f "$APPS_JSON" ] && jq -e '.apps | type == "array"' "$APPS_JSON" > /dev/null 2>&1; then
        echo "OK: package apps.json parses"
    else
        echo "FAIL: $APPS_JSON missing or not the expected shape"
    fi

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

# The base's Portal parsed as YAML, not as the lines the build cut: the group
# is gone and the group after it is still there.
check_portal_group_removed() {
    local id=$1 next=$2

    if python3 - "$id" "$next" << 'EOF'; then
import sys, yaml
ids = set()
def walk(node):
    if isinstance(node, dict):
        if "id" in node:
            ids.add(node["id"])
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
walk(yaml.safe_load(open("/usr/share/yafti/yafti.yml")))
sys.exit(0 if sys.argv[1] not in ids and sys.argv[2] in ids else 1)
EOF
        echo "OK: the Portal has no $id group, and its $next group stays"
    else
        echo "FAIL: the Portal still has its $id group, lost $next or does not parse"
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
