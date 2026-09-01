#!/usr/bin/bash
# system-setup hook: remove the system-wide Firefox flatpak (Firefox
# ships as the Mozilla RPM instead).
#
# Runs once per version (versioning via libsetup.sh); bump the version
# below to re-run on the next boot of already-configured systems.

set -euo pipefail

# shellcheck disable=SC1091
source /usr/lib/ublue/setup-services/libsetup.sh

version-script cleanup-firefox-flatpak system 1 || exit 0

echo "Cleaning up pre-existing system flatpak Firefox (if any)..."
flatpak uninstall -y --system --noninteractive org.mozilla.firefox 2>/dev/null || true

echo "system cleanup-firefox-flatpak hook complete."
