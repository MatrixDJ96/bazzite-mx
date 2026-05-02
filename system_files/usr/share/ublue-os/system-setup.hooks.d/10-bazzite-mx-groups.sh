#!/usr/bin/bash
# bazzite-mx system-setup hook: append docker/libvirt groups and grant
# them to wheel users on first boot.
#
# Runs from /usr/libexec/ublue-system-setup as root (after rpm-ostreed,
# before systemd-user-sessions). Idempotency comes from libsetup.sh's
# version-script helper, which keeps state in
# /var/roothome/.local/share/ublue/setup_versioning.json (since /root
# is a symlink to /var/roothome on bootc atomic; persists across deploys).
#
# Bumping the third arg of `version-script` re-runs the hook on every
# user the next time the system boots. Useful when the TARGET_GROUPS
# list changes.

set -euo pipefail

# shellcheck disable=SC1091
source /usr/lib/ublue/setup-services/libsetup.sh

version-script bazzite-mx-groups system 1 || exit 0

# Append a group from /usr/lib/group (vendor) into /etc/group (mutable)
# if it isn't already there. Required because atomic distros only seed
# /etc/group with a minimal subset; package-installed groups land in
# /usr/lib/group and have to be merged at runtime.
append_group() {
    local group_name="$1"
    if ! grep -q "^${group_name}:" /etc/group; then
        if grep -q "^${group_name}:" /usr/lib/group 2>/dev/null; then
            echo "Appending ${group_name} to /etc/group"
            grep "^${group_name}:" /usr/lib/group >> /etc/group
        else
            echo "WARNING: group ${group_name} not in /usr/lib/group; skipping"
            return 0
        fi
    fi
}

TARGET_GROUPS=(docker libvirt)

for g in "${TARGET_GROUPS[@]}"; do
    append_group "$g"
done

# Add every wheel user to the target groups. usermod -aG is idempotent.
mapfile -t WHEEL_USERS < <(getent group wheel | cut -d ':' -f 4 | tr ',' '\n' | grep -v '^$' || true)
for user in "${WHEEL_USERS[@]}"; do
    for g in "${TARGET_GROUPS[@]}"; do
        if getent group "$g" >/dev/null; then
            echo "Adding ${user} to ${g}"
            usermod -aG "$g" "$user"
        fi
    done
done

echo "bazzite-mx-groups system-setup hook complete."
