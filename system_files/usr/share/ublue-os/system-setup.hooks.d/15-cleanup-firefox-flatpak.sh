#!/usr/bin/bash
# system-setup hook: rimuove la flatpak Firefox system-wide
# pre-esistente per chi aggiorna da una bazzite-mx pre-Mozilla-RPM.
#
# Eseguito una sola volta per versione (versioning via libsetup.sh).
# Per riapplicare in futuro (es. se cambiamo logica): bump del numero
# di versione qui sotto e l'hook rigira automaticamente al boot
# successivo, anche su sistemi già configurati.

set -euo pipefail

# shellcheck disable=SC1091
source /usr/lib/ublue/setup-services/libsetup.sh

version-script cleanup-firefox-flatpak system 1 || exit 0

echo "Cleaning up pre-existing system flatpak Firefox (if any)..."
flatpak uninstall -y --system --noninteractive org.mozilla.firefox 2>/dev/null || true

echo "system cleanup-firefox-flatpak hook complete."
