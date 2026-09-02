#!/usr/bin/env bash
# bazzite-mx system-setup hook: every wheel member gets the groups of the
# services this image ships (GROUPS_TARGET below). Converges on every boot:
# no version stamp, no state file; a user created after the first boot is
# picked up at the next one. bazzite-dx gates the same work behind
# libsetup's version-script (privileged-setup.hooks.d/20-dx.sh:5), which
# records the run BEFORE the body executes and so never repeats a failed
# run nor reaches a later user.
#
# Runs as root from ublue-system-setup.service (ublue-setup-services 0.1.8:
# After=rpm-ostreed.service, Before=systemd-user-sessions.service). The
# dispatcher invokes `bash <script>` and reads no exit status, so a failure
# is printed loudly: the journal line is the only signal it leaves.
#
# The groups themselves exist in /usr/lib/group (package %post at build,
# relocated there by 95-clean-stage.sh) and NSS resolves them
# (nsswitch.conf: files, altfiles), but usermod edits /etc/group only, so the
# line is copied over first (bazzite-dx 20-dx.sh:8-14 does the same).
#
# Fixture mode, used by build_files/tests/21-container-runtime.sh:
# BAZZITE_MX_GROUPS_PREFIX names a tree with etc/passwd, etc/group and
# usr/lib/group; usermod --prefix (shadow-utils 4.19) edits that tree.
set -euo pipefail

GROUPS_TARGET=(docker)
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
