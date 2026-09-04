#!/usr/bin/env bash
# NTFSPLUS as the type `ntfs` on every flavour: 50-kmods.sh installed ntfs.ko
# under updates/, ahead of the 7.2 kernel's own fs/ntfs. The 6.18 kernel of
# bazzite-nvidia has no fs/ntfs, and once it sets CONFIG_NTFS_FS its ntfs3
# registers a read-only `ntfs` of its own, so there the image routes fs-ntfs to
# NTFSPLUS and loads NTFSPLUS before ntfs3. The generic mount.ntfs helpers go,
# because mount(8) hands the type to one before the kernel ever sees it.
#
# Usage: run by build.sh after 50-kmods.sh; no arguments.
# Writes: /usr/lib/modprobe.d/bazzite-mx-ntfs.conf, only on a kernel whose
#   ntfs3 carries the fs-ntfs alias; removes /usr/bin/mount.ntfs and
#   mount.ntfs-fuse (/usr/sbin is a link to bin).
# Exit status: 0 done; the build stops on a `FAIL: …` line, or on modinfo's
#   own message for a kernel without ntfs3.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"
# shellcheck source=lib/kmod.sh
source "$BUILD_FILES/lib/kmod.sh"

ROUTING=/usr/lib/modprobe.d/bazzite-mx-ntfs.conf
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

# Of two drivers registering one type only the first loaded gets it
# (fs/ntfs3/super.c, init_ntfs_fs), hence the softdep besides the alias.
route_legacy_ntfs() {
    local kernel=$1
    local ntfs3 aliases

    ntfs3=$(modinfo -k "$kernel" -F filename ntfs3)
    aliases=$(modinfo -F alias "$ntfs3")

    if ! grep -qx fs-ntfs <<< "$aliases"; then
        return 0
    fi

    {
        echo "# ntfs3 of this kernel registers a read-only ntfs too: NTFSPLUS takes the"
        echo "# type, as on the 7.2 kernel (build_files/55-ntfsplus.sh)."
        echo "alias fs-ntfs ntfs"
        echo "softdep ntfs3 pre: ntfs"
    } > "$ROUTING"
}

# mount.ntfs-3g stays, the explicit FUSE route.
remove_generic_helpers() {
    rm -f "${GENERIC_HELPERS[@]}"

    if [ ! -x /usr/sbin/mount.ntfs-3g ]; then
        fail_build "mount.ntfs-3g missing: the FUSE route must stay"
    fi
}

# fs-ntfs reaches NTFSPLUS alone, and with the routing file ntfs3 loads it
# first. --show-depends, because -v prints nothing for a module the builder's
# kernel already has loaded.
require_ntfs_routed() {
    local kernel=$1
    local want="insmod /lib/modules/$kernel/updates/ntfs.ko"
    local resolution first

    resolution=$(modprobe -S "$kernel" -n --show-depends fs-ntfs 2>&1 | sed 's/ *$//' || true)

    if [ "$resolution" != "$want" ]; then
        fail_build "fs-ntfs resolves to '$resolution', expected '$want' alone"
    fi

    if [ ! -f "$ROUTING" ]; then
        return 0
    fi

    first=$(modprobe -S "$kernel" -n --show-depends ntfs3 2>&1 | head -n 1 | sed 's/ *$//' || true)

    if [ "$first" != "$want" ]; then
        fail_build "ntfs3 does not load NTFSPLUS first: modprobe ntfs3 starts with '$first'"
    fi
}

# --- main ---------------------------------------------------------------------

kernel=$(kernel_version)
module_file=/usr/lib/modules/$kernel/updates/ntfs.ko

require_module_alias "$module_file"
route_legacy_ntfs "$kernel"
require_ntfs_routed "$kernel"
remove_generic_helpers

if [ -f "$ROUTING" ]; then
    log "ntfsplus: $module_file takes fs-ntfs, loaded before ntfs3 ($ROUTING);" \
        "mount.ntfs helpers removed"
else
    log "ntfsplus: $module_file takes fs-ntfs over the kernel's own fs/ntfs;" \
        "mount.ntfs helpers removed"
fi
