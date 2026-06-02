#!/usr/bin/bash
# MX block 71: install the out-of-tree acpi_ec module built in the kmod-builder
# stage, then regenerate modules.dep. acpi_ec creates the /dev/ec char device
# (the ogc kernel builds with CONFIG_ACPI_EC_DEBUGFS off, so ec_sys's debugfs is
# unavailable), which MControlCenter uses for fan RPM and curves. No in-tree copy
# exists, so updates/ overrides nothing. Activation stays opt-in via
# `ujust setup-msi`; no autoload is shipped.
echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core | head -1)
SRC="/run/kmods/updates/drivers/acpi/acpi_ec.ko.xz"
DEST="/usr/lib/modules/${KVER}/updates/drivers/acpi/acpi_ec.ko.xz"

[ -f "$SRC" ] || { echo "FAIL: $SRC missing (kmod-builder stage produced no acpi_ec)"; exit 1; }

install -Dm644 "$SRC" "$DEST"
depmod "$KVER"

echo "::endgroup::"
