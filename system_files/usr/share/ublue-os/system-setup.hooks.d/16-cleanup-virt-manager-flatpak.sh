#!/usr/bin/bash
# system-setup hook: remove the system-wide virt-manager flatpak for
# users upgrading from a build that never had RPM virt-manager (or
# users who manually `flatpak install --system org.virt_manager.virt-
# manager` thinking it was the default path).
#
# Runs once per version (versioning via libsetup.sh). To re-apply in
# the future (e.g. if we change the logic): bump the version number
# below and the hook re-runs automatically on the next boot, even on
# already-configured systems.

set -euo pipefail

# shellcheck disable=SC1091
source /usr/lib/ublue/setup-services/libsetup.sh

version-script cleanup-virt-manager-flatpak system 1 || exit 0

echo "Cleaning up pre-existing system flatpak virt-manager (if any)..."
flatpak uninstall -y --system --noninteractive org.virt_manager.virt-manager 2>/dev/null || true

echo "system cleanup-virt-manager-flatpak hook complete."
