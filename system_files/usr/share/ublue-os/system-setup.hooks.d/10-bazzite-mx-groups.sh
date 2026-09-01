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
# user the next time the system boots (e.g. when TARGET_GROUPS changes).
# The docker group is created early by /usr/lib/sysusers.d/bazzite-mx-
# docker.conf via systemd-sysusers, so usermod -aG docker succeeds here.

set -euo pipefail

# shellcheck disable=SC1091
source /usr/lib/ublue/setup-services/libsetup.sh

version-script bazzite-mx-groups system 2 || exit 0

# Append a group from /usr/lib/group (vendor) into /etc/group (mutable)
# if it isn't already there. Required because atomic distros only seed
# /etc/group with a minimal subset; package-installed groups land in
# /usr/lib/group and have to be merged at runtime.
#
# On the current base neither path is taken: upstream's relocate_accounts
# runs BEFORE our docker-ce / libvirt installs, so /etc/group already
# carries docker and libvirt at first boot and /usr/lib/group carries
# neither (MEASURED 2026-09-01 on the preflight image and on
# ldesktop-zrombi). The merge stays for the case it was written for; what
# changed is the third branch. Reaching it means a real regression -- a
# dropped sysusers.d entry, a renamed group -- and the hook used to
# answer it with one WARNING line and carry on as if nothing happened.
MISSING_GROUPS=()
append_group() {
    local group_name="$1"
    if ! grep -q "^${group_name}:" /etc/group; then
        if grep -q "^${group_name}:" /usr/lib/group 2>/dev/null; then
            echo "Appending ${group_name} to /etc/group"
            grep "^${group_name}:" /usr/lib/group >> /etc/group
        else
            MISSING_GROUPS+=("$group_name")
            return 0
        fi
    fi
}

TARGET_GROUPS=(docker libvirt)

for g in "${TARGET_GROUPS[@]}"; do
    append_group "$g"
done

# Add every wheel user to the target groups. usermod -aG is idempotent.
# Best-effort: libsetup writes its version state before this body runs,
# so a hard usermod failure (e.g. /etc/passwd lock contention at sysinit)
# would abort the hook permanently for the remaining users.
mapfile -t WHEEL_USERS < <(getent group wheel | cut -d ':' -f 4 | tr ',' '\n' | grep -v '^$' || true)
for user in "${WHEEL_USERS[@]}"; do
    for g in "${TARGET_GROUPS[@]}"; do
        if getent group "$g" >/dev/null; then
            echo "Adding ${user} to ${g}"
            usermod -aG "$g" "$user" || true
        fi
    done
done

# Reported last, so the users that CAN be served still are. The dispatcher
# runs hooks with a bare `bash $script` and reads no exit status, so this
# journal line is the only signal a missing group will ever produce -- and
# `version-script` has already stamped the run, which is why it has to be
# loud rather than silently retried.
if [ "${#MISSING_GROUPS[@]}" -gt 0 ]; then
    echo "ERROR: group(s) ${MISSING_GROUPS[*]} exist in neither /etc/group nor /usr/lib/group;" >&2
    echo "       no wheel user was added to them. Check their /usr/lib/sysusers.d entry" >&2
    echo "       (docker: bazzite-mx-docker.conf, libvirt: libvirt's own libvirt.conf)." >&2
    exit 1
fi

echo "bazzite-mx-groups system-setup hook complete."
