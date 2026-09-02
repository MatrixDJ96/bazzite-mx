#!/usr/bin/env bash
# Every wheel member gets the groups of the services this image ships. Root,
# from ublue-system-setup.service, on every boot: no state file, so a user
# created later is picked up at the next boot.
#
# BAZZITE_MX_GROUPS_PREFIX=<dir> names the tree the smoke test builds
# (etc/passwd, etc/group, usr/lib/group), which usermod --prefix edits.
set -euo pipefail

GROUPS_TARGET=(docker libvirt)
PREFIX=${BAZZITE_MX_GROUPS_PREFIX:-}
ETC_GROUP=$PREFIX/etc/group
LIB_GROUP=$PREFIX/usr/lib/group
usermod_opts=()
[ -z "$PREFIX" ] || usermod_opts=(--prefix "$PREFIX")

# Members of a group as listed in /etc/group (human users live there).
members_of() {
    awk -F: -v g="$1" '$1 == g { n = split($4, m, ","); for (i = 1; i <= n; i++) if (m[i] != "") print m[i] }' "$ETC_GROUP"
}

# The groups exist in /usr/lib/group and NSS resolves them, but usermod edits
# /etc/group only: the line is copied over first.
missing=()
for g in "${GROUPS_TARGET[@]}"; do
    if grep -q "^${g}:" "$ETC_GROUP"; then
        continue
    fi
    if line=$(grep "^${g}:" "$LIB_GROUP"); then
        echo "bazzite-mx-groups: copying $g from $LIB_GROUP to $ETC_GROUP"
        echo "$line" >> "$ETC_GROUP"
    else
        missing+=("$g")
    fi
done

mapfile -t wheel < <(members_of wheel)
for user in "${wheel[@]}"; do
    for g in "${GROUPS_TARGET[@]}"; do
        grep -q "^${g}:" "$ETC_GROUP" || continue
        if members_of "$g" | grep -qx "$user"; then
            continue
        fi
        echo "bazzite-mx-groups: adding $user to $g"
        usermod "${usermod_opts[@]}" -aG "$g" "$user"
    done
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "bazzite-mx-groups: ERROR: group(s) ${missing[*]} exist in neither $ETC_GROUP nor $LIB_GROUP; no wheel user was added to them" >&2
    exit 1
fi
echo "bazzite-mx-groups: ${#wheel[@]} wheel user(s) in ${GROUPS_TARGET[*]}"
