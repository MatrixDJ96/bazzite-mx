#!/usr/bin/bash
# system-setup hook: remove the system-wide pre-existing Firefox flatpak
# for users upgrading from a pre-Mozilla-RPM bazzite-mx.
#
# Runs once per version (versioning via libsetup.sh). To re-apply in
# the future (e.g. if we change the logic): bump the version number
# below and the hook re-runs automatically on the next boot, even on
# already-configured systems.

set -euo pipefail

# shellcheck disable=SC1091
source /usr/lib/ublue/setup-services/libsetup.sh

version-script cleanup-firefox-flatpak system 1 || exit 0

echo "Cleaning up pre-existing system flatpak Firefox (if any)..."
flatpak uninstall -y --system --noninteractive org.mozilla.firefox 2>/dev/null || true

echo "system cleanup-firefox-flatpak hook complete."
