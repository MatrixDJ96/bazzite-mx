#!/usr/bin/env bash
# Smoke test of 55-ntfsplus.sh: the ntfs.ko under updates/ takes fs-ntfs alone,
# and where the kernel's ntfs3 claims fs-ntfs too, ntfs3 loads NTFSPLUS first,
# elsewhere the image adds no modprobe file; no generic mount.ntfs helper, the
# FUSE route kept, and udisks's ntfs options with errors=remount-ro.
# The runtime mount is proven on a booted host (docs/divergences.md § NTFSPLUS on
# every flavour).
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines. The test
# itself stops when kernel_version finds two kernels or none.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
# shellcheck source=../lib/log.sh
source "$CTX/build_files/lib/log.sh"
# shellcheck source=../lib/kmod.sh
source "$CTX/build_files/lib/kmod.sh"

ROUTING=/usr/lib/modprobe.d/bazzite-mx-ntfs.conf
UDISKS_OPTIONS=/etc/udisks2/mount_options.conf

# The vermagic and the explicit resolution are 50-kmods.sh's, which walks
# every kmods/*/source.env and so covers this module too; what is this
# feature's own is the filesystem alias.
check_module() {
    local module=$1

    if [ -f "$module" ] && [ "$(modinfo -F alias "$module" 2> /dev/null)" = fs-ntfs ]; then
        echo "OK: $module registers the filesystem type ntfs" \
            "(alias fs-ntfs, $(stat -c %s "$module") bytes)"
    else
        echo "FAIL: $module missing or without the fs-ntfs alias"
    fi
}

# --show-depends, because -v prints nothing for a module the running kernel
# already has loaded.
check_alias_resolution() {
    local kernel=$1
    local want="insmod /lib/modules/$kernel/updates/ntfs.ko"
    local resolution

    resolution=$(modprobe -S "$kernel" -n --show-depends fs-ntfs 2>&1 | sed 's/ *$//' || true)

    if [ "$resolution" = "$want" ]; then
        echo "OK: modprobe fs-ntfs inserts updates/ntfs.ko alone"
    else
        echo "FAIL: modprobe fs-ntfs would run: $(on_one_line 'no output' <<< "$resolution")"
    fi
}

# Whether ntfs3 claims fs-ntfs is read off the kernel's own module, not off
# the file the build wrote.
check_ntfs3_order() {
    local kernel=$1
    local want="insmod /lib/modules/$kernel/updates/ntfs.ko"
    local ntfs3 aliases first

    ntfs3=$(modinfo -k "$kernel" -F filename ntfs3 2> /dev/null || true)
    aliases=$(modinfo -F alias "$ntfs3" 2> /dev/null || true)

    if ! grep -qx fs-ntfs <<< "$aliases"; then
        if [ ! -e "$ROUTING" ]; then
            echo "OK: ntfs3 does not claim fs-ntfs and no $ROUTING ships"
        else
            echo "FAIL: $ROUTING ships on a kernel whose ntfs3 does not claim fs-ntfs"
        fi

        return 0
    fi

    first=$(modprobe -S "$kernel" -n --show-depends ntfs3 2>&1 | head -n 1 | sed 's/ *$//' || true)

    if [ "$first" = "$want" ]; then
        echo "OK: ntfs3 claims fs-ntfs and modprobe ntfs3 inserts updates/ntfs.ko first"
    else
        echo "FAIL: ntfs3 claims fs-ntfs but modprobe ntfs3 starts with:" \
            "$(on_one_line 'no output' <<< "$first")"
    fi
}

# --- the mount helpers --------------------------------------------------------

# A generic helper would take `mount -t ntfs` to FUSE before the kernel sees
# the type; the explicit FUSE route stays.
check_mount_helpers() {
    local helper left=""

    for helper in /usr/bin/mount.ntfs /usr/bin/mount.ntfs-fuse; do
        if [ -e "$helper" ] || [ -L "$helper" ]; then
            left+=" $helper"
        fi
    done

    if [ -z "$left" ]; then
        echo "OK: no generic mount.ntfs helper"
    else
        echo "FAIL: generic helpers still present:$left"
    fi

    if [ -x /usr/sbin/mount.ntfs-3g ] && [ -x /usr/bin/ntfs-3g ]; then
        echo "OK: mount -t ntfs-3g remains the explicit FUSE route"
    else
        echo "FAIL: mount.ntfs-3g or ntfs-3g missing"
    fi
}

# --- udisks -------------------------------------------------------------------

# Each ntfs key of the image's file is udisksd's builtin one plus
# errors=remount-ro: the file replaces a set whole, so an option a udisks
# update adds to the builtin set would otherwise be dropped in silence.
check_udisks_options() {
    local builtin key want got

    builtin=$(strings /usr/libexec/udisks2/udisksd 2> /dev/null || true)

    for key in ntfs:ntfs_defaults ntfs:ntfs_allow; do
        want=$(grep -m1 "^$key=" <<< "$builtin" || true)
        got=$(sed -n '/^\[defaults\]$/,/^\[/p' "$UDISKS_OPTIONS" 2> /dev/null \
            | grep -m1 "^$key=" || true)

        if [ -n "$want" ] && [ "$got" = "$want,errors=remount-ro" ]; then
            echo "OK: $UDISKS_OPTIONS: $key is udisksd's builtin set plus errors=remount-ro"
        else
            echo "FAIL: $UDISKS_OPTIONS: $key is '${got:-absent}'," \
                "expected udisksd's '${want:-absent}' plus ,errors=remount-ro"
        fi
    done
}

# --- main ---------------------------------------------------------------------

kernel=$(kernel_version)

check_module "/usr/lib/modules/$kernel/updates/ntfs.ko"
check_alias_resolution "$kernel"
check_ntfs3_order "$kernel"
check_mount_helpers
check_udisks_options
