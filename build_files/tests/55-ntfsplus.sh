#!/usr/bin/env bash
# Smoke test of 55-ntfsplus.sh: the ntfs.ko under updates/, the blacklist
# that keeps the kernel off it, the removed mount.ntfs helpers, the FUSE
# route kept, Bazzite's ntfs-nag.service disabled for users, udisks's ntfs
# options with errors=remount-ro, and the opt-in helper with its self-test.
# The runtime mount is proven on a booted host (docs/divergences.md).
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

BLACKLIST=/usr/lib/modprobe.d/bazzite-mx-ntfsplus.conf
OPTIN=/etc/modprobe.d/bazzite-mx-ntfsplus.conf
HELPER=/usr/libexec/bazzite-mx-ntfsplus-setup
NAG_UNIT=ntfs-nag.service
GENERIC_HELPERS=(/usr/bin/mount.ntfs /usr/bin/mount.ntfs-fuse)
UDISKS_OPTIONS=/etc/udisks2/mount_options.conf

# --- the module ---------------------------------------------------------------

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

# Exactly one directive in the image's file, and no opt-in file: the opt-in
# is the host's.
check_blacklist() {
    local directives

    directives=$(grep -vE '^\s*(#|$)' "$BLACKLIST" 2>&1 || true)

    if [ "$directives" = "blacklist ntfs" ]; then
        echo "OK: $BLACKLIST blacklists ntfs (loaded by alias only once a host masks it)"
    else
        echo "FAIL: $BLACKLIST missing or not exactly 'blacklist ntfs':" \
            "$(on_one_line empty <<< "$directives")"
    fi

    if [ ! -e "$OPTIN" ]; then
        echo "OK: no $OPTIN in the image (the opt-in is the host's)"
    else
        echo "FAIL: $OPTIN ships with the image: ntfsplus would be the default"
    fi
}

# The alias must be indexed, or the empty resolution would mean "no alias"
# instead of "blacklisted".
check_alias_resolution() {
    local kernel=$1
    local alias_out

    if grep -qx "alias fs-ntfs ntfs" "/usr/lib/modules/$kernel/modules.alias" 2> /dev/null; then
        echo "OK: modules.alias indexes fs-ntfs -> ntfs"
    else
        echo "FAIL: modules.alias has no 'alias fs-ntfs ntfs' line"
    fi

    alias_out=$(modprobe -S "$kernel" -n -v fs-ntfs 2>&1 || true)

    if [ -z "$alias_out" ]; then
        echo "OK: modprobe fs-ntfs resolves to nothing (blacklisted alias)"
    else
        echo "FAIL: modprobe fs-ntfs would run: $(on_one_line 'no output' <<< "$alias_out")"
    fi
}

# --- the mount helpers --------------------------------------------------------

# With the generic helpers gone the type ntfs reaches the kernel on every
# path: fstab, .mount units, mount -t auto. The explicit FUSE route stays.
check_mount_helpers() {
    local helper link

    for helper in "${GENERIC_HELPERS[@]}"; do
        if [ ! -e "$helper" ] && [ ! -L "$helper" ]; then
            echo "OK: $helper gone"
        else
            link=$(readlink "$helper" 2> /dev/null || true)
            echo "FAIL: $helper still present (${link:-file})"
        fi
    done

    if [ -x /usr/sbin/mount.ntfs-3g ] && [ -x /usr/bin/ntfs-3g ]; then
        echo "OK: mount -t ntfs-3g remains the explicit FUSE route"
    else
        echo "FAIL: mount.ntfs-3g or ntfs-3g missing"
    fi

    check_pkg ntfs-3g ntfsprogs

    if [ -x /usr/sbin/mkntfs ]; then
        echo "OK: mkntfs present"
    else
        echo "FAIL: /usr/sbin/mkntfs missing"
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
module=/usr/lib/modules/$kernel/updates/ntfs.ko

check_module "$module"
check_blacklist
check_alias_resolution "$kernel"
check_mount_helpers
check_unit_state --global "$NAG_UNIT" disabled "an NTFSPLUS volume is type ntfs"
check_udisks_options
check_self_test ntfsplus-setup "$HELPER"
