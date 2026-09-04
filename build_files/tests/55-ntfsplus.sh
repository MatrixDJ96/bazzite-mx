#!/usr/bin/env bash
# The ntfs.ko under updates/, the blacklist that keeps the kernel off it, the
# removed mount.ntfs helpers, the FUSE route kept, and the opt-in helper. The
# runtime mount is proven on a booted host (docs/divergences.md).
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
# shellcheck source=../lib/log.sh
source "$CTX/build_files/lib/log.sh"
# shellcheck source=../lib/kmod.sh
source "$CTX/build_files/lib/kmod.sh"
# kernel_version dies, and this test with it, on two kernels or none.
kver=$(kernel_version)
ko=/usr/lib/modules/$kver/updates/ntfs.ko
BLACKLIST=/usr/lib/modprobe.d/bazzite-mx-ntfsplus.conf
OPTIN=/etc/modprobe.d/bazzite-mx-ntfsplus.conf
HELPER=/usr/libexec/bazzite-mx-ntfsplus-setup
RECIPES=/usr/share/ublue-os/just/95-bazzite-mx.just

if [ -f "$ko" ] && [ "$(modinfo -F alias "$ko" 2> /dev/null)" = fs-ntfs ]; then
    echo "OK: $ko registers the filesystem type ntfs (alias fs-ntfs, $(stat -c %s "$ko") bytes)"
else
    echo "FAIL: $ko missing or without the fs-ntfs alias"
fi
vermagic=$(modinfo -F vermagic "$ko" 2> /dev/null || true)
if [[ $vermagic == "$kver "* ]]; then
    echo "OK: ntfs vermagic names $kver"
else
    echo "FAIL: ntfs vermagic '$vermagic' does not name $kver"
fi

# Exactly one directive, `blacklist ntfs`.
if [ "$(grep -vE '^\s*(#|$)' "$BLACKLIST" 2> /dev/null)" = "blacklist ntfs" ]; then
    echo "OK: $BLACKLIST blacklists ntfs (loaded by alias only once a host masks it)"
else
    echo "FAIL: $BLACKLIST missing or not exactly 'blacklist ntfs': $(grep -vE '^\s*(#|$)' "$BLACKLIST" 2>&1 | tr '\n' ' ')"
fi
if [ ! -e "$OPTIN" ]; then
    echo "OK: no $OPTIN in the image (the opt-in is the host's)"
else
    echo "FAIL: $OPTIN ships with the image: ntfsplus would be the default"
fi

# The alias must be indexed, or the empty resolution below would mean "no
# alias" instead of "blacklisted".
if grep -qx "alias fs-ntfs ntfs" "/usr/lib/modules/$kver/modules.alias"; then
    echo "OK: modules.alias indexes fs-ntfs -> ntfs"
else
    echo "FAIL: modules.alias has no 'alias fs-ntfs ntfs' line"
fi
alias_out=$(modprobe -S "$kver" -n -v fs-ntfs 2>&1 || true)
if [ -z "$alias_out" ]; then
    echo "OK: modprobe fs-ntfs resolves to nothing (blacklisted alias)"
else
    echo "FAIL: modprobe fs-ntfs would run: $(tr '\n' ' ' <<< "$alias_out")"
fi
resolved=$({ modprobe -S "$kver" -n --show-depends ntfs 2>&1 || true; } | awk '$1 == "insmod" { print $2 }' | tail -n1)
if [ -n "$resolved" ] && [ "$(realpath "$resolved")" = "$(realpath "$ko")" ]; then
    echo "OK: modprobe ntfs (explicit) resolves to $resolved"
else
    echo "FAIL: modprobe ntfs resolves to '$resolved', not $ko"
fi

# With the generic helpers gone the type ntfs reaches the kernel on every
# path: fstab, .mount units, mount -t auto.
for p in /usr/bin/mount.ntfs /usr/bin/mount.ntfs-fuse /usr/sbin/mount.ntfs /usr/sbin/mount.ntfs-fuse; do
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then
        echo "OK: $p gone"
    else
        echo "FAIL: $p still present ($(readlink "$p" 2> /dev/null || echo file))"
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

if [ -x "$HELPER" ] && [ "$(stat -c %a "$HELPER")" = 755 ] && bash -n "$HELPER"; then
    echo "OK: $HELPER executable (755), parses"
else
    echo "FAIL: $HELPER missing, wrong mode or does not parse"
fi
out=$("$HELPER" --self-test 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && grep -q '^self-test ok' <<< "$out"; then
    echo "OK: ntfsplus-setup self-test: $(tail -n1 <<< "$out")"
else
    echo "FAIL: ntfsplus-setup self-test (exit $rc): $(tail -n3 <<< "$out" | tr '\n' ' ')"
fi
if has_recipe "$RECIPES" setup-ntfsplus; then
    echo "OK: recipe file defines setup-ntfsplus"
else
    echo "FAIL: recipe summary: $(just --justfile "$RECIPES" --summary 2>&1)"
fi
check_recipe_help "$RECIPES" setup-ntfsplus
