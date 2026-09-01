#!/usr/bin/bash
# user-setup hook: remove the per-user virt-manager flatpak (--user)
# for users who added it manually via Discover/Bazaar before we
# extended the blocklist.
#
# Complementary to the same-named system-setup hook: two distinct
# flatpak namespaces (system vs user), both need to be covered.
#
# Versioned: bumping the number below re-runs the hook on next login.

set -euo pipefail

# shellcheck disable=SC1091
source /usr/lib/ublue/setup-services/libsetup.sh

version-script cleanup-virt-manager-flatpak user 1 || exit 0

echo "Cleaning up pre-existing user flatpak virt-manager (if any)..."
flatpak uninstall -y --user --noninteractive org.virt_manager.virt-manager 2>/dev/null || true

echo "user cleanup-virt-manager-flatpak hook complete."
