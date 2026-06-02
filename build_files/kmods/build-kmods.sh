#!/usr/bin/bash
# Generic out-of-tree kmod builder. Runs in the Containerfile `kmod-builder`
# stage (executable base image). For each module in KMODS: clone its pinned
# source, compile against the matched kernel-devel from the akmods carrier,
# and stage the xz-compressed .ko under /out/<KO_DEST>/ for the final stage.
echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

CTX="${CTX:-/ctx}"
: "${KERNEL_VERSION:?KERNEL_VERSION must be set}"

# KERNEL_VERSION is the base image's ostree.linux label; on Bazzite it equals the
# installed kernel-core NVRA, so the module compiled here lands in the same
# /usr/lib/modules/<kver>/ tree that 70-msi-ec.sh derives from `rpm -q kernel-core`.
KSRC="/usr/src/kernels/${KERNEL_VERSION}"

# Toolchain + the matched kernel-devel bind-mounted from the akmods carrier.
# dnf5 (not bare `dnf`): on F44+ /usr/bin/dnf is a compat shim that only
# redirects to dnf5 inside a container marker — project convention is dnf5.
dnf5 install -y gcc make git xz elfutils-libelf-devel \
    "/run/kernel-rpms/kernel-devel-${KERNEL_VERSION}.rpm"

[ -d "$KSRC" ] || { echo "FAIL: $KSRC missing after kernel-devel install"; exit 1; }

# Modules to build (extend this list for future kmods).
KMODS=(msi-ec acpi_ec)

for kmod in "${KMODS[@]}"; do
    # Clear per-module vars so an unset KO_BUILD_PATH never leaks across iterations.
    unset URL COMMIT KO_NAME KO_DEST KO_BUILD_PATH
    # shellcheck disable=SC1090
    source "$CTX/build_files/kmods/${kmod}/source.env"   # URL, COMMIT, KO_NAME, KO_DEST[, KO_BUILD_PATH]
    # Where the kbuild output .ko lands relative to the clone root. Defaults to
    # the root (msi-ec); modules whose Makefile builds in a subdir set it.
    : "${KO_BUILD_PATH:=${KO_NAME}.ko}"
    src="/tmp/build-${kmod}"
    git clone "$URL" "$src"
    git -C "$src" -c advice.detachedHead=false checkout "$COMMIT"
    # Build against the TARGET kernel, not the builder's running kernel:
    # call the kernel build system directly (the module's own `modules`
    # target hardcodes /lib/modules/$(uname -r)/build).
    make -C "$KSRC" M="$src" modules
    # Compress for the kernel-side XZ module decompressor, which accepts ONLY
    # CRC32 + a small dictionary. Default `xz` uses CRC64 + an 8 MiB dict, which
    # decompresses fine in userspace but makes modprobe fail with "decompression
    # failed" at load. These flags match kernel modinst / akmods convention.
    xz --check=crc32 --lzma2=dict=1MiB -f "$src/${KO_BUILD_PATH}"
    install -Dm644 "$src/${KO_BUILD_PATH}.xz" "/out/${KO_DEST}/${KO_NAME}.ko.xz"
done

echo "::endgroup::"
