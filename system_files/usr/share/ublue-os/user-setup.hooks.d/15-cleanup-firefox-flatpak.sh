#!/usr/bin/bash
# user-setup hook: rimuove la flatpak Firefox installata per-utente
# (--user) da chi l'ha aggiunta manualmente con `flatpak install --user`.
#
# Complementare al hook system-setup omonimo: due namespace flatpak
# distinti (system vs user), entrambi vanno coperti.
#
# Versioned: bump del numero qui sotto rigira l'hook al login successivo.

set -euo pipefail

# shellcheck disable=SC1091
source /usr/lib/ublue/setup-services/libsetup.sh

version-script cleanup-firefox-flatpak user 1 || exit 0

echo "Cleaning up pre-existing user flatpak Firefox (if any)..."
flatpak uninstall -y --user --noninteractive org.mozilla.firefox 2>/dev/null || true

echo "user cleanup-firefox-flatpak hook complete."
