#!/usr/bin/bash
# user-setup hook: remove the per-user Firefox flatpak (--user) for
# users who added it manually with `flatpak install --user`.
#
# Complementary to the same-named system-setup hook: two distinct
# flatpak namespaces (system vs user), both need to be covered.
#
# Versioned: bumping the number below re-runs the hook on next login.

set -euo pipefail

# shellcheck disable=SC1091
source /usr/lib/ublue/setup-services/libsetup.sh

version-script cleanup-firefox-flatpak user 1 || exit 0

echo "Cleaning up pre-existing user flatpak Firefox (if any)..."
flatpak uninstall -y --user --noninteractive org.mozilla.firefox 2>/dev/null || true

echo "user cleanup-firefox-flatpak hook complete."
