#!/usr/bin/env bash
# Every wheel member gets the groups of the services this image ships, docker
# and libvirt. Root, from ublue-system-setup.service, on every boot: no state
# file, so a user created later is picked up at the next boot.
#
# Usage: 10-bazzite-mx-groups.sh        (root; ublue-system-setup runs it)
#   BAZZITE_MX_GROUPS_PREFIX=<dir> names the tree the smoke test builds
#   (etc/passwd, etc/group, usr/lib/group), which usermod --prefix edits.
# Output: `bazzite-mx-groups: …` lines, the last one the count of wheel users
#   and the groups (tests/21-container-runtime.sh reads it).
# Exit status: 0 done; 1 a target group exists in neither group file, the
#   groups named in a `bazzite-mx-groups: ERROR: …` line on stderr.
set -euo pipefail

# tests/22-virtualization.sh reads this line for libvirt.
GROUPS_TARGET=(docker libvirt)

PREFIX=${BAZZITE_MX_GROUPS_PREFIX:-}
ETC_GROUP=$PREFIX/etc/group
LIB_GROUP=$PREFIX/usr/lib/group

USERMOD_OPTIONS=()
if [ -n "$PREFIX" ]; then
    USERMOD_OPTIONS=(--prefix "$PREFIX")
fi

# Filled by copy_groups_to_etc: the target groups found in neither file.
MISSING_GROUPS=()

# --- the group files ----------------------------------------------------------

# members_of <group>: one member per line, as /etc/group lists them (human
# users live there).
members_of() {
    local group=$1

    awk -F: -v group="$group" '
        $1 == group {
            count = split($4, members, ",")
            for (i = 1; i <= count; i++) {
                if (members[i] != "") {
                    print members[i]
                }
            }
        }' "$ETC_GROUP"
}

group_in_etc() {
    local group=$1

    grep -q "^${group}:" "$ETC_GROUP"
}

# The groups exist in /usr/lib/group and NSS resolves them, but usermod edits
# /etc/group only: the line is copied over first.
copy_groups_to_etc() {
    local group line

    for group in "${GROUPS_TARGET[@]}"; do
        if group_in_etc "$group"; then
            continue
        fi

        if line=$(grep "^${group}:" "$LIB_GROUP"); then
            echo "bazzite-mx-groups: copying $group from $LIB_GROUP to $ETC_GROUP"
            echo "$line" >> "$ETC_GROUP"
        else
            MISSING_GROUPS+=("$group")
        fi
    done
}

# --- the wheel users ----------------------------------------------------------

# add_wheel_users_to_groups <user>...: each user joins every target group
# present in /etc/group that does not list them yet.
add_wheel_users_to_groups() {
    local user group members

    for user in "$@"; do
        for group in "${GROUPS_TARGET[@]}"; do
            if ! group_in_etc "$group"; then
                continue
            fi

            members=$(members_of "$group")
            if grep -qx "$user" <<< "$members"; then
                continue
            fi

            echo "bazzite-mx-groups: adding $user to $group"
            usermod "${USERMOD_OPTIONS[@]}" -aG "$group" "$user"
        done
    done
}

# --- main ---------------------------------------------------------------------

main() {
    local wheel_users

    copy_groups_to_etc

    mapfile -t wheel_users < <(members_of wheel)
    add_wheel_users_to_groups "${wheel_users[@]}"

    if [ ${#MISSING_GROUPS[@]} -gt 0 ]; then
        echo "bazzite-mx-groups: ERROR: group(s) ${MISSING_GROUPS[*]} exist in neither $ETC_GROUP" \
            "nor $LIB_GROUP; no wheel user was added to them" >&2
        exit 1
    fi

    echo "bazzite-mx-groups: ${#wheel_users[@]} wheel user(s) in ${GROUPS_TARGET[*]}"
}

main "$@"
