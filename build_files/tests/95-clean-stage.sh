#!/usr/bin/env bash
# What clean-stage left: /var holding only cache, an empty log and tmp, /boot
# empty, /var/tmp 1777, /etc down to root and wheel without its lock files,
# the rpmdb hardlinked, dnf's history gone, versionlock and Flathub untouched.
set -euo pipefail

check() {
    local label=$1
    shift
    if "$@"; then
        echo "OK: $label"
    else
        echo "FAIL: $label"
    fi
}

var_only_expected() {
    local extra
    extra=$(find /var -mindepth 1 -maxdepth 1 ! -name cache ! -name log ! -name tmp)
    [ -z "$extra" ]
}
check "/var holds only cache, log, tmp" var_only_expected
check "/var/log is empty" test -z "$(find /var/log -mindepth 1 2> /dev/null)"
check "/var/tmp is 1777" test "$(stat -c %a /var/tmp)" = 1777
check "/boot is empty" test -z "$(find /boot -mindepth 1 2> /dev/null)"
check "/etc/passwd carries only root" test "$(grep -vc '^root:' /etc/passwd)" = 0
check "/etc/group carries only root and wheel" test "$(grep -vcE '^(root|wheel):' /etc/group)" = 0
check "no /etc/passwd- style lock files" test -z "$(ls /etc/passwd- /etc/group- /etc/shadow- /etc/gshadow- /etc/.pwd.lock 2> /dev/null)"
check "rpmdb hardlinked into rpm-ostree-base-db" test /usr/share/rpm/rpmdb.sqlite -ef /usr/lib/sysimage/rpm-ostree-base-db/rpmdb.sqlite
check "dnf5 transaction history removed" test -z "$(ls -A /usr/lib/sysimage/libdnf5 2> /dev/null)"
check "kernel versionlock kept" bash -c 'dnf5 -q versionlock list 2>/dev/null | grep -q "^Package name: kernel$"'
check "flatpak-add-fedora-repos.service left as the base ships it" test "$(systemctl is-enabled flatpak-add-fedora-repos.service)" = enabled
