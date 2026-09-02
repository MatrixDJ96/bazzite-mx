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

LOCK_FILES=(/etc/passwd- /etc/group- /etc/shadow- /etc/gshadow- /etc/.pwd.lock)
RPMDB=/usr/share/rpm/rpmdb.sqlite
BASE_DB=/usr/lib/sysimage/rpm-ostree-base-db/rpmdb.sqlite
DNF_HISTORY=/usr/lib/sysimage/libdnf5

# --- /var and /boot -----------------------------------------------------------

check_var_and_boot() {
    local extra

    extra=$(find /var -mindepth 1 -maxdepth 1 ! -name cache ! -name log ! -name tmp)
    if [ -z "$extra" ]; then
        echo "OK: /var holds only cache, log, tmp"
    else
        echo "FAIL: /var holds only cache, log, tmp"
    fi

    if [ "$(stat -c %a /var/tmp)" = 1777 ]; then
        echo "OK: /var/tmp is 1777"
    else
        echo "FAIL: /var/tmp is 1777"
    fi

    if [ -z "$(find /boot -mindepth 1 2> /dev/null)" ]; then
        echo "OK: /boot is empty"
    else
        echo "FAIL: /boot is empty"
    fi
}

# --- /etc ---------------------------------------------------------------------

check_accounts() {
    if [ "$(grep -vc '^root:' /etc/passwd)" = 0 ]; then
        echo "OK: /etc/passwd carries only root"
    else
        echo "FAIL: /etc/passwd carries only root"
    fi

    if [ "$(grep -vcE '^(root|wheel):' /etc/group)" = 0 ]; then
        echo "OK: /etc/group carries only root and wheel"
    else
        echo "FAIL: /etc/group carries only root and wheel"
    fi

    if [ -z "$(ls "${LOCK_FILES[@]}" 2> /dev/null)" ]; then
        echo "OK: no /etc/passwd- style lock files"
    else
        echo "FAIL: no /etc/passwd- style lock files"
    fi
}

# --- the package databases ----------------------------------------------------

check_package_databases() {
    if [ "$RPMDB" -ef "$BASE_DB" ]; then
        echo "OK: rpmdb hardlinked into rpm-ostree-base-db"
    else
        echo "FAIL: rpmdb hardlinked into rpm-ostree-base-db"
    fi

    if [ -z "$(ls -A "$DNF_HISTORY" 2> /dev/null)" ]; then
        echo "OK: dnf5 transaction history removed"
    else
        echo "FAIL: dnf5 transaction history removed"
    fi

    # Captured first: the base's lock list runs to thousands of lines since
    # 2026-09-07 and a `| grep -q` on it dies of SIGPIPE under pipefail
    # (docs/gotchas.md § `command | grep -q` under `pipefail`).
    local locks
    locks=$(dnf5 -q versionlock list 2> /dev/null || true)

    if grep -q '^Package name: kernel$' <<< "$locks"; then
        echo "OK: kernel versionlock kept"
    else
        echo "FAIL: kernel versionlock kept"
    fi
}

check_flathub_unit() {
    if [ "$(systemctl is-enabled flatpak-add-fedora-repos.service)" = enabled ]; then
        echo "OK: flatpak-add-fedora-repos.service left as the base ships it"
    else
        echo "FAIL: flatpak-add-fedora-repos.service left as the base ships it"
    fi
}

# --- main ---------------------------------------------------------------------

check_var_and_boot
check_accounts
check_package_databases
check_flathub_unit
