#!/usr/bin/env bash
# Every wheel member gets the group of the service this image ships, docker.
# Root, from ublue-system-setup.service, on every boot: no state file, so a
# user created later is picked up at the next boot. The hook only adds:
# leaving wheel does not take docker away.
# A group whose /etc/group gid differs from the image's (the image fixes it,
# usr/lib/sysusers.d/bazzite-mx-groups.conf) takes the image's number when no
# other group holds it, and the files under /run (docker.sock, created before
# this hook) and /etc with the old gid follow first, so a
# walk cut short by a poweroff runs again. Each is walked on its own
# filesystem; the homes and the container stores are not walked, their
# files carrying gids of their own in the same range; a file the old gid gave
# another group of the image moves too.
#
# Usage: 10-bazzite-mx-groups.sh        (root; ublue-system-setup runs it)
#   BAZZITE_MX_GROUPS_PREFIX=<dir> names the tree the smoke test builds
#   (etc/passwd, etc/group, usr/lib/group), which usermod --prefix edits.
# Output: `bazzite-mx-groups: …` lines, the last one the count of wheel users
#   and the groups.
# Writes: /etc/group and /etc/gshadow (groupmod, usermod), the group of the
#   files under /run and /etc that carried a realigned
#   group's old gid.
# Exit status: 0 done; non-zero when groupmod or usermod fails, their own
#   message on stderr.
set -euo pipefail

GROUPS_TARGET=(docker)

PREFIX=${BAZZITE_MX_GROUPS_PREFIX:-}
ETC_GROUP=$PREFIX/etc/group
LIB_GROUP=$PREFIX/usr/lib/group

USERMOD_OPTIONS=()

if [ -n "$PREFIX" ]; then
    USERMOD_OPTIONS=(--prefix "$PREFIX")
fi

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

        if ! find "$PREFIX/run" "$PREFIX/etc" -xdev -gid "$etc_gid" \
            -exec chgrp -h "$lib_gid" {} +; then
            echo "bazzite-mx-groups: some files under /run and /etc" \
                "kept gid $etc_gid" >&2
        fi

        # The number is the group's own line in /usr/lib/group, which groupmod
        # reads through NSS as taken: -o lets the two lines agree.
        groupmod "${USERMOD_OPTIONS[@]}" -o -g "$lib_gid" "$group"
    done
}

# The groups exist in /usr/lib/group and NSS resolves them, but usermod edits
# /etc/group only: the line is copied over first.
copy_groups_to_etc() {
    local group

    for group in "${GROUPS_TARGET[@]}"; do
        if ! group_in_etc "$group"; then
            echo "bazzite-mx-groups: copying $group from $LIB_GROUP to $ETC_GROUP"
            grep "^${group}:" "$LIB_GROUP" >> "$ETC_GROUP"
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
            usermod "${USERMOD_OPTIONS[@]}" -aG "$group" "$user"
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
