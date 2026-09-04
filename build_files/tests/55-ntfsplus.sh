#!/usr/bin/env bash
# Smoke test of 55-ntfsplus.sh: the ntfs.ko under updates/, the blacklist
# that keeps the kernel off it, the removed mount.ntfs helpers, the FUSE
# route kept, and the opt-in helper with its self-test. The runtime mount is
# proven on a booted host (docs/divergences.md).
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
RECIPES=/usr/share/ublue-os/just/95-bazzite-mx.just
GENERIC_HELPERS=(/usr/bin/mount.ntfs /usr/bin/mount.ntfs-fuse /usr/sbin/mount.ntfs
    /usr/sbin/mount.ntfs-fuse)

# --- the module ---------------------------------------------------------------

check_module() {
    local kernel=$1
    local module=$2
    local vermagic

    if [ -f "$module" ] && [ "$(modinfo -F alias "$module" 2> /dev/null)" = fs-ntfs ]; then
        echo "OK: $module registers the filesystem type ntfs" \
            "(alias fs-ntfs, $(stat -c %s "$module") bytes)"
    else
        echo "FAIL: $module missing or without the fs-ntfs alias"
    fi

    vermagic=$(modinfo -F vermagic "$module" 2> /dev/null || true)
    if [[ $vermagic == "$kernel "* ]]; then
        echo "OK: ntfs vermagic names $kernel"
    else
        echo "FAIL: ntfs vermagic '$vermagic' does not name $kernel"
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
            "$(tr '\n' ' ' <<< "$directives")"
    fi

    if [ ! -e "$OPTIN" ]; then
        echo "OK: no $OPTIN in the image (the opt-in is the host's)"
    else
        echo "FAIL: $OPTIN ships with the image: ntfsplus would be the default"
    fi
}

# The alias must be indexed, or the empty resolution would mean "no alias"
# instead of "blacklisted"; the explicit name still resolves to updates/.
check_alias_resolution() {
    local kernel=$1
    local module=$2
    local alias_out resolved

    if grep -qx "alias fs-ntfs ntfs" "/usr/lib/modules/$kernel/modules.alias"; then
        echo "OK: modules.alias indexes fs-ntfs -> ntfs"
    else
        echo "FAIL: modules.alias has no 'alias fs-ntfs ntfs' line"
    fi

    alias_out=$(modprobe -S "$kernel" -n -v fs-ntfs 2>&1 || true)
    if [ -z "$alias_out" ]; then
        echo "OK: modprobe fs-ntfs resolves to nothing (blacklisted alias)"
    else
        echo "FAIL: modprobe fs-ntfs would run: $(tr '\n' ' ' <<< "$alias_out")"
    fi

    resolved=$({ modprobe -S "$kernel" -n --show-depends ntfs 2>&1 || true; } \
        | awk '$1 == "insmod" { print $2 }' \
        | tail -n1)
    if [ -n "$resolved" ] && [ "$(realpath "$resolved")" = "$(realpath "$module")" ]; then
        echo "OK: modprobe ntfs (explicit) resolves to $resolved"
    else
        echo "FAIL: modprobe ntfs resolves to '$resolved', not $module"
    fi
}

# --- the mount helpers --------------------------------------------------------

# With the generic helpers gone the type ntfs reaches the kernel on every
# path: fstab, .mount units, mount -t auto. The explicit FUSE route stays.
check_mount_helpers() {
    local helper

    for helper in "${GENERIC_HELPERS[@]}"; do
        if [ ! -e "$helper" ] && [ ! -L "$helper" ]; then
            echo "OK: $helper gone"
        else
            echo "FAIL: $helper still present ($(readlink "$helper" 2> /dev/null || echo file))"
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

# --- the opt-in helper --------------------------------------------------------

check_helper() {
    local self_test_out self_test_rc

    if [ -x "$HELPER" ] && [ "$(stat -c %a "$HELPER")" = 755 ] && bash -n "$HELPER"; then
        echo "OK: $HELPER executable (755), parses"
    else
        echo "FAIL: $HELPER missing, wrong mode or does not parse"
    fi

    if self_test_out=$("$HELPER" --self-test 2>&1); then
        self_test_rc=0
    else
        self_test_rc=$?
    fi

    if [ "$self_test_rc" -eq 0 ] && grep -q '^self-test ok' <<< "$self_test_out"; then
        echo "OK: ntfsplus-setup self-test: $(tail -n1 <<< "$self_test_out")"
    else
        echo "FAIL: ntfsplus-setup self-test (exit $self_test_rc):" \
            "$(tail -n3 <<< "$self_test_out" | tr '\n' ' ')"
    fi
}

check_recipe() {
    if has_recipe "$RECIPES" setup-ntfsplus; then
        echo "OK: recipe file defines setup-ntfsplus"
    else
        echo "FAIL: recipe summary: $(just --justfile "$RECIPES" --summary 2>&1)"
    fi

    check_recipe_help "$RECIPES" setup-ntfsplus
}

# --- main ---------------------------------------------------------------------

kernel=$(kernel_version)
module=/usr/lib/modules/$kernel/updates/ntfs.ko

check_module "$kernel" "$module"
check_blacklist
check_alias_resolution "$kernel" "$module"
check_mount_helpers
check_helper
check_recipe
