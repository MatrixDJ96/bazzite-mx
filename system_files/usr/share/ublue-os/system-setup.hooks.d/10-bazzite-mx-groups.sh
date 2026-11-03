#!/usr/bin/env bash
# Every wheel member joins docker and libvirt, at every boot with no state
# file, so a later user is picked up; leaving wheel takes nothing away.
# A group whose /etc/group gid differs from the image's (sysusers.d) takes the
# image's when no other group holds it. The files under /run (docker.sock
# predates this hook), /etc and /var/lib/libvirt with the old gid follow first,
# so a run killed mid-walk runs again; a file of another group on that gid moves
# too. Homes and container stores are not walked: their gids are their own.
#
# Usage: 10-bazzite-mx-groups.sh        (root; ublue-system-setup runs it)
#   BAZZITE_MX_GROUPS_PREFIX=<dir> names the tree the smoke test builds
#   (etc/passwd, etc/group, usr/lib/group), which usermod --prefix edits.
# Output: `bazzite-mx-groups: …` lines, the last one the count of wheel users
#   and the groups.
# Writes: /etc/group (lines copied from /usr/lib/group, the gid field, usermod)
#   and /etc/gshadow (usermod), the group of the files under /run, /etc and
#   /var/lib/libvirt that carried a realigned group's old gid.
# Exit status: 0 done; 1 when a group line's copy, the /etc/group rewrite or
#   usermod fails, in a `bazzite-mx-groups: ERROR: …` line on stderr after the
#   failing tool's own message when it prints one.
set -euo pipefail

GROUPS_TARGET=(docker libvirt)

PREFIX=${BAZZITE_MX_GROUPS_PREFIX:-}
ETC_GROUP=$PREFIX/etc/group
LIB_GROUP=$PREFIX/usr/lib/group

USERMOD_OPTIONS=()

if [ -n "$PREFIX" ]; then
    USERMOD_OPTIONS=(--prefix "$PREFIX")
fi

exit_with_error() {
    echo "bazzite-mx-groups: ERROR: $*" >&2
    exit 1
}

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

# gid_in <file> <group>: the group's gid in that file, empty without a line.
gid_in() {
    local file=$1 group=$2

    awk -F: -v group="$group" '$1 == group { print $3; exit }' "$file"
}

# realign_gids: each target group in /etc/group on another gid than the
# image's takes the image's, unless another group of either file holds it.
realign_gids() {
    local group etc_gid lib_gid holder

    for group in "${GROUPS_TARGET[@]}"; do
        etc_gid=$(gid_in "$ETC_GROUP" "$group")
        lib_gid=$(gid_in "$LIB_GROUP" "$group")

        if [ -z "$etc_gid" ] || [ "$etc_gid" = "$lib_gid" ]; then
            continue
        fi

        holder=$(awk -F: -v gid="$lib_gid" -v group="$group" \
            '$3 == gid && $1 != group { print $1; exit }' "$ETC_GROUP" "$LIB_GROUP")

        if [ -n "$holder" ]; then
            echo "bazzite-mx-groups: $group keeps gid $etc_gid:" \
                "the image's $lib_gid is $holder's"
            continue
        fi

        echo "bazzite-mx-groups: moving $group from gid $etc_gid to $lib_gid"

        if ! find "$PREFIX/run" "$PREFIX/etc" "$PREFIX/var/lib/libvirt" -xdev -gid "$etc_gid" \
            -exec chgrp -h "$lib_gid" {} +; then
            echo "bazzite-mx-groups: some files under /run, /etc and /var/lib/libvirt" \
                "kept gid $etc_gid" >&2
        fi

        if ! set_gid_in_etc "$group" "$lib_gid"; then
            exit_with_error "cannot set $group's gid to $lib_gid in $ETC_GROUP"
        fi
    done
}

# set_gid_in_etc <group> <gid>: rewrites the gid field of the group's line; a
# user whose primary gid is the old one keeps it. Not groupmod, which fails on a
# `/usr/lib/passwd` user whose primary gid is the old one.
set_gid_in_etc() {
    local group=$1 gid=$2
    local staged=$ETC_GROUP.bazzite-mx

    # The copy first, so the renamed file keeps /etc/group's mode, owner and label.
    if ! cp --preserve=all "$ETC_GROUP" "$staged" \
        || ! awk -F: -v OFS=: -v group="$group" -v gid="$gid" \
            '$1 == group { $3 = gid } { print }' "$ETC_GROUP" > "$staged" \
        || ! mv -f "$staged" "$ETC_GROUP"; then
        return 1
    fi
}

# The groups exist in /usr/lib/group and NSS resolves them, but usermod edits
# /etc/group only: the line is copied over first.
copy_groups_to_etc() {
    local group

    for group in "${GROUPS_TARGET[@]}"; do
        if ! group_in_etc "$group"; then
            echo "bazzite-mx-groups: copying $group from $LIB_GROUP to $ETC_GROUP"

            if ! grep "^${group}:" "$LIB_GROUP" >> "$ETC_GROUP"; then
                exit_with_error "cannot copy $group from $LIB_GROUP to $ETC_GROUP"
            fi
        fi
    done
}

# --- the wheel users ----------------------------------------------------------

# add_wheel_users_to_groups <user>...: each user joins every target group
# that does not list them yet.
add_wheel_users_to_groups() {
    local user group members

    for user in "$@"; do
        for group in "${GROUPS_TARGET[@]}"; do
            members=$(members_of "$group")

            if grep -qx "$user" <<< "$members"; then
                continue
            fi

            echo "bazzite-mx-groups: adding $user to $group"

            if ! usermod "${USERMOD_OPTIONS[@]}" -aG "$group" "$user"; then
                exit_with_error "usermod could not add $user to $group"
            fi
        done
    done
}

# --- main ---------------------------------------------------------------------

main() {
    local wheel_users

    realign_gids
    copy_groups_to_etc

    mapfile -t wheel_users < <(members_of wheel)
    add_wheel_users_to_groups "${wheel_users[@]}"

    echo "bazzite-mx-groups: ${#wheel_users[@]} wheel user(s) in ${GROUPS_TARGET[*]}"
}

main "$@"
