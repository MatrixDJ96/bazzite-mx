#!/usr/bin/env bash
# Lets qemu:///system, whose domains run as the qemu user, read an ISO kept in
# the home: an ACL u:qemu:rx on HOME, every graphical session (/run/media and
# /var/mnt get theirs from tmpfiles.d/bazzite-mx-virt.conf).
#
# Usage: 13-bazzite-mx-qemu-home.sh   (as the user; ublue-user-setup runs it)
#   The smoke test points HOME at a fixture directory.
# Output: one `bazzite-mx-qemu-home: …` line saying whether the ACL was set.
# Exit status: 0 done; 1 setfacl failed, in a `bazzite-mx-qemu-home: ERROR: …`
#   line on stderr.
set -euo pipefail

acl=$(getfacl -p "$HOME" 2> /dev/null || true)

if grep -qx 'user:qemu:r-x' <<< "$acl"; then
    echo "bazzite-mx-qemu-home: $HOME already readable by qemu"
    exit 0
fi

if ! error=$(setfacl -m u:qemu:rx "$HOME" 2>&1); then
    echo "bazzite-mx-qemu-home: ERROR: setfacl on $HOME failed: $error;" \
        "retried at the next login" >&2
    exit 1
fi

echo "bazzite-mx-qemu-home: $HOME made readable by qemu"
