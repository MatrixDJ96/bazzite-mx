#!/usr/bin/env bash
# Smoke test of 95-clean-stage.sh, what clean-stage left: /var holding only
# cache, log and tmp, /boot empty, /var/tmp 1777, /etc down to root and
# wheel without its lock files, the rpmdb hardlinked, dnf's history gone,
# versionlock and Flathub untouched.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

LOCK_FILES=(/etc/passwd- /etc/group- /etc/shadow- /etc/gshadow- /etc/subuid- /etc/subgid-
    /etc/.pwd.lock)
RPMDB=/usr/share/rpm/rpmdb.sqlite
BASE_DB=/usr/lib/sysimage/rpm-ostree-base-db/rpmdb.sqlite
DNF_HISTORY=/usr/lib/sysimage/libdnf5

# --- /var and /boot -----------------------------------------------------------

check_var_and_boot() {
    local extra mode boot

    extra=$(find /var -mindepth 1 -maxdepth 1 ! -name cache ! -name log ! -name tmp 2>&1 || true)

    if [ -z "$extra" ]; then
        echo "OK: /var holds only cache, log, tmp"
    else
        echo "FAIL: /var also holds ${extra//$'\n'/ }"
    fi

    mode=$(stat -c %a /var/tmp 2>&1 || true)

    if [ "$mode" = 1777 ]; then
        echo "OK: /var/tmp is 1777"
    else
        echo "FAIL: /var/tmp is '${mode:-empty}', want 1777"
    fi

    boot=$(find /boot -mindepth 1 2>&1 || true)

    if [ -z "$boot" ]; then
        echo "OK: /boot is empty"
    else
        echo "FAIL: /boot holds ${boot//$'\n'/ }"
    fi
}

# --- /etc ---------------------------------------------------------------------

# A table this test cannot read is not a table carrying only root: the build
# script moves both files (95-clean-stage.sh), so the failure this check
# exists to catch is exactly the one an unreadable file would hide.
check_accounts() {
    local users groups locks

    if [ ! -r /etc/passwd ] || [ ! -s /etc/passwd ]; then
        echo "FAIL: /etc/passwd missing, empty or unreadable"
    else
        users=$(grep -v '^root:' /etc/passwd | cut -d: -f1 || true)

        if [ -z "$users" ]; then
            echo "OK: /etc/passwd carries only root"
        else
            echo "FAIL: /etc/passwd also carries ${users//$'\n'/ }"
        fi
    fi

    if [ ! -r /etc/group ] || [ ! -s /etc/group ]; then
        echo "FAIL: /etc/group missing, empty or unreadable"
    else
        groups=$(grep -vE '^(root|wheel):' /etc/group | cut -d: -f1 || true)

        if [ -z "$groups" ]; then
            echo "OK: /etc/group carries only root and wheel"
        else
            echo "FAIL: /etc/group also carries ${groups//$'\n'/ }"
        fi
    fi

    locks=$(ls "${LOCK_FILES[@]}" 2> /dev/null || true)

    if [ -z "$locks" ]; then
        echo "OK: no /etc/passwd- style lock files"
    else
        echo "FAIL: lock files left: ${locks//$'\n'/ }"
    fi
}

# --- the package databases ----------------------------------------------------

check_package_databases() {
    local inodes history locks lock_lines

    if [ "$RPMDB" -ef "$BASE_DB" ]; then
        echo "OK: rpmdb hardlinked into rpm-ostree-base-db"
    else
        inodes=$(stat -c '%n %i' "$RPMDB" "$BASE_DB" 2>&1 || true)
        echo "FAIL: rpmdb not hardlinked into rpm-ostree-base-db: ${inodes//$'\n'/, }"
    fi

    history=$(ls -A "$DNF_HISTORY" 2> /dev/null || true)

    if [ -z "$history" ]; then
        echo "OK: dnf5 transaction history removed"
    else
        echo "FAIL: dnf5 transaction history left: ${history//$'\n'/ }"
    fi

    locks=$(dnf5 -q versionlock list 2> /dev/null || true)

    if grep -q '^Package name: kernel$' <<< "$locks"; then
        echo "OK: kernel versionlock kept"
    else
        lock_lines=$(grep -c '^Package name: ' <<< "$locks" || true)
        echo "FAIL: kernel versionlock gone, $lock_lines package(s) locked"
    fi
}

# --- main ---------------------------------------------------------------------

check_var_and_boot
check_accounts
check_package_databases
check_unit_state flatpak-add-fedora-repos.service enabled "left as the base ships it"
