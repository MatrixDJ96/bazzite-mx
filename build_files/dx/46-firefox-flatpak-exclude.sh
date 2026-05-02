#!/usr/bin/bash
# DX block 46: esclude la flatpak Firefox dal default-install Bazzite e
# la nasconde da Discover/Bazaar.
#
# Companion di 45-firefox-rpm.sh: dato che Firefox ora arriva dal repo
# Mozilla come rpm, vogliamo evitare che bazzite-flatpak-manager
# installi anche la versione flatpak al primo boot, e che Discover/
# Bazaar suggeriscano la flatpak come "alternativa" all'utente.
#
# Strategia drift-tolerant: invece di overrideare i file Bazzite con
# nostre versioni statiche (che sarebbero out-of-date al primo upgrade
# upstream), patchiamo i file in-place a build-time:
#  - sed: rimuove la riga org.mozilla.firefox dalla install list
#  - grep || echo: aggiunge deny org.mozilla.firefox/* al blocklist
#    se non già presente (idempotente)
#
# I file Bazzite di riferimento:
#  /usr/share/ublue-os/bazzite/flatpak/install   (default-install list)
#  /usr/share/ublue-os/flatpak-blocklist         (Flathub remote filter)

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

INSTALL_LIST=/usr/share/ublue-os/bazzite/flatpak/install
BLOCKLIST=/usr/share/ublue-os/flatpak-blocklist

### Section 1: rimuovi org.mozilla.firefox dalla default-install list ###
# Sanity check sul file: deve esistere (se Bazzite cambia path in
# futuro fail-fast invece di no-op silenzioso).
if [ ! -f "$INSTALL_LIST" ]; then
    echo "FAIL: $INSTALL_LIST non trovato (Bazzite ha cambiato struttura?)"
    exit 1
fi
sed -i '/^org\.mozilla\.firefox$/d' "$INSTALL_LIST"

### Section 2: estendi flatpak-blocklist con Firefox ###
# Idempotente: append solo se la riga non c'è già. Estendiamo invece
# che sostituire per non perdere le entries upstream (Steam, Lutris,
# eventuali aggiunte future).
if [ ! -f "$BLOCKLIST" ]; then
    echo "FAIL: $BLOCKLIST non trovato (Bazzite ha cambiato struttura?)"
    exit 1
fi
grep -q '^deny org\.mozilla\.firefox/\*$' "$BLOCKLIST" \
    || echo "deny org.mozilla.firefox/*" >> "$BLOCKLIST"

echo "::endgroup::"
