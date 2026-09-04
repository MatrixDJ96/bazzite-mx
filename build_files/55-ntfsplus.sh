#!/usr/bin/env bash
# NTFSPLUS as a per-host opt-in: the driver ships blacklisted and
# `ujust setup-ntfsplus enable` masks that. The generic mount.ntfs helpers go,
# because mount(8) hands the type to one before the kernel ever sees it.
#
# Usage: run by build.sh after 50-kmods.sh; no arguments.
# Writes: removes /usr/bin/mount.ntfs and mount.ntfs-fuse (/usr/sbin is a
#   link to bin), and disables Bazzite's ntfs-nag.service for users. The
#   blacklist itself comes from system_files/.
# Exit status: 0 done; the build stops on a `FAIL: …` line; a base that no
#   longer ships the nag unit stops it on systemctl's own message.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"
# shellcheck source=lib/kmod.sh
source "$BUILD_FILES/lib/kmod.sh"

BLACKLIST=/usr/lib/modprobe.d/bazzite-mx-ntfsplus.conf
HOST_OPT_IN=/etc/modprobe.d/bazzite-mx-ntfsplus.conf
NAG_UNIT=ntfs-nag.service
GENERIC_HELPERS=(
    /usr/bin/mount.ntfs
    /usr/bin/mount.ntfs-fuse
)

# --- the steps ----------------------------------------------------------------

# The module 50-kmods.sh installed must be the one the kernel would pick for
# an `ntfs` file system: its alias is fs-ntfs.
require_module_alias() {
    local module_file=$1
    local alias

    alias=$(modinfo -F alias "$module_file")

    if [ "$alias" != fs-ntfs ]; then
        fail_build "$module_file alias '$alias', expected fs-ntfs"
    fi
}

# The image blacklists the driver and never carries the host's opt-in file.
require_blacklist() {
    local directive

    directive=$(grep -vE '^\s*(#|$)' "$BLACKLIST" 2> /dev/null || true)

    if [ "$directive" != "blacklist ntfs" ]; then
        fail_build "$BLACKLIST must carry exactly 'blacklist ntfs', got '$directive'"
    fi

    if [ -e "$HOST_OPT_IN" ]; then
        fail_build "$HOST_OPT_IN in the image: the opt-in must stay the host's"
    fi
}

# The FUSE route stays reachable by its own name, and mkntfs serves the
# helper's runtime probe.
remove_generic_helpers() {
    local helper

    for helper in "${GENERIC_HELPERS[@]}"; do
        rm -f "$helper"
    done

    if [ ! -x /usr/sbin/mount.ntfs-3g ] || [ ! -x /usr/bin/ntfs-3g ]; then
        fail_build "mount.ntfs-3g or ntfs-3g missing: the FUSE route must stay"
    fi

    if [ ! -x /usr/sbin/mkntfs ]; then
        fail_build "mkntfs missing: the helper's runtime probe needs it"
    fi
}

# Bazzite enables this user unit for everyone and its script nags on every
# ntfs, exfat or fuseblk mount that appears after the session started; an
# NTFSPLUS volume is type ntfs, so the base would nag against the feature the
# image ships.
disable_nag_unit() {
    local state

    systemctl --global disable "$NAG_UNIT"
    state=$(systemctl --global is-enabled "$NAG_UNIT" 2> /dev/null || true)

    if [ "$state" != disabled ]; then
        fail_build "$NAG_UNIT is ${state:-without a state} for users (expected disabled)"
    fi
}

# The alias must be indexed, or an empty resolution would mean "no alias"
# instead of "blacklisted"; then the blacklist must stop fs-ntfs while the
# module name still resolves to our file.
require_alias_indexed_and_masked() {
    local kernel=$1
    local module_file=$2
    local resolution resolved

    if ! grep -qx "alias fs-ntfs ntfs" "/usr/lib/modules/$kernel/modules.alias"; then
        fail_build "modules.alias has no 'alias fs-ntfs ntfs' line"
    fi

    resolution=$(modprobe -S "$kernel" -n -v fs-ntfs 2>&1 || true)

    if [ -n "$resolution" ]; then
        fail_build "fs-ntfs still resolves with the blacklist in place: $resolution"
    fi

    resolved=$({ modprobe -S "$kernel" -n --show-depends ntfs 2>&1 || true; } \
        | awk '$1 == "insmod" { print $2 }' \
        | tail -n1)

    if [ -z "$resolved" ] || [ "$(realpath "$resolved")" != "$(realpath "$module_file")" ]; then
        fail_build "modprobe ntfs resolves to '$resolved', not $module_file"
    fi
}

# --- main ---------------------------------------------------------------------

kernel=$(kernel_version)
module_file=/usr/lib/modules/$kernel/updates/ntfs.ko

require_module_alias "$module_file"
require_blacklist
remove_generic_helpers
disable_nag_unit
require_alias_indexed_and_masked "$kernel" "$module_file"

log "ntfsplus: $module_file (alias fs-ntfs, indexed) blacklisted by $BLACKLIST," \
    "mount.ntfs and mount.ntfs-fuse helpers removed, mount.ntfs-3g kept," \
    "Bazzite's $NAG_UNIT disabled for users"
