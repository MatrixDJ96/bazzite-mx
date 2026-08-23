#!/usr/bin/bash
# MX block 70: install the out-of-tree msi-ec module built in the kmod-builder
# stage into the image's updates/ tree (highest depmod priority → overrides the
# obsolete in-tree copy), then regenerate modules.dep. Activation stays opt-in
# via `ujust setup-msi`; no autoload is shipped here.
echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core | head -1)
SRC="/run/kmods/updates/drivers/platform/x86/msi-ec.ko.xz"
DEST="/usr/lib/modules/${KVER}/updates/drivers/platform/x86/msi-ec.ko.xz"

[ -f "$SRC" ] || { echo "FAIL: $SRC missing (kmod-builder stage produced no msi-ec)"; exit 1; }

install -Dm644 "$SRC" "$DEST"
depmod "$KVER"

echo "::endgroup::"
