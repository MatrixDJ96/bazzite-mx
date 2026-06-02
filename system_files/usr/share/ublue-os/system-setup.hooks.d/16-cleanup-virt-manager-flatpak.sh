#!/usr/bin/bash
# system-setup hook: remove the system-wide virt-manager flatpak
# (virt-manager ships as an RPM instead).
#
# Runs once per version (versioning via libsetup.sh); bump the version
# below to re-run on the next boot of already-configured systems.

set -euo pipefail

# shellcheck disable=SC1091
source /usr/lib/ublue/setup-services/libsetup.sh

version-script cleanup-virt-manager-flatpak system 1 || exit 0

echo "Cleaning up pre-existing system flatpak virt-manager (if any)..."
flatpak uninstall -y --system --noninteractive org.virt_manager.virt-manager 2>/dev/null || true

echo "system cleanup-virt-manager-flatpak hook complete."
