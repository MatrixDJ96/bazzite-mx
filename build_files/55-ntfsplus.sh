#!/usr/bin/env bash
# NTFSPLUS as a per-host opt-in: the driver ships blacklisted and
# `ujust setup-ntfsplus enable` masks that. The generic mount.ntfs helpers go,
# because mount(8) hands the type to one before the kernel ever sees it.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"
# shellcheck source=lib/kmod.sh
source "$BUILD_FILES/lib/kmod.sh"

BLACKLIST=/usr/lib/modprobe.d/bazzite-mx-ntfsplus.conf
HELPERS=(/usr/bin/mount.ntfs /usr/bin/mount.ntfs-fuse /usr/sbin/mount.ntfs /usr/sbin/mount.ntfs-fuse)

kver=$(kernel_version)
ko=/usr/lib/modules/$kver/updates/ntfs.ko
[ -f "$ko" ] || die "$ko missing: 50-kmods.sh did not install ntfsplus"
alias=$(modinfo -F alias "$ko")
[ "$alias" = fs-ntfs ] || die "$ko alias '$alias', expected fs-ntfs"

directive=$(grep -vE '^\s*(#|$)' "$BLACKLIST" 2> /dev/null || true)
[ "$directive" = "blacklist ntfs" ] || die "$BLACKLIST must carry exactly 'blacklist ntfs', got '$directive'"
[ ! -e /etc/modprobe.d/bazzite-mx-ntfsplus.conf ] || die "/etc/modprobe.d/bazzite-mx-ntfsplus.conf in the image: the opt-in must stay the host's"

for h in "${HELPERS[@]}"; do
    rm -f "$h"
    [ ! -e "$h" ] && [ ! -L "$h" ] || die "$h still present"
done
[ -x /usr/sbin/mount.ntfs-3g ] && [ -x /usr/bin/ntfs-3g ] || die "mount.ntfs-3g or ntfs-3g missing: the FUSE route must stay"
[ -x /usr/sbin/mkntfs ] || die "mkntfs missing: the helper's runtime probe needs it"

# The alias must be indexed, or the empty resolution below would mean "no
# alias" instead of "blacklisted".
grep -qx "alias fs-ntfs ntfs" "/usr/lib/modules/$kver/modules.alias" || die "modules.alias has no 'alias fs-ntfs ntfs' line"
out=$(modprobe -S "$kver" -n -v fs-ntfs 2>&1 || true)
[ -z "$out" ] || die "fs-ntfs still resolves with the blacklist in place: $out"
resolved=$({ modprobe -S "$kver" -n --show-depends ntfs 2>&1 || true; } | awk '$1 == "insmod" { print $2 }' | tail -n1)
[ -n "$resolved" ] && [ "$(realpath "$resolved")" = "$(realpath "$ko")" ] || die "modprobe ntfs resolves to '$resolved', not $ko"

log "ntfsplus: $ko (alias fs-ntfs, indexed) blacklisted by $BLACKLIST, mount.ntfs and mount.ntfs-fuse helpers removed, mount.ntfs-3g kept"
