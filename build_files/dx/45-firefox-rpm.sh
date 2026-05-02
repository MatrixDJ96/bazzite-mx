#!/usr/bin/bash
# DX block 45: Firefox dal repo RPM ufficiale di Mozilla.
#
# Bazzite di default installa Firefox come flatpak Flathub
# (org.mozilla.firefox). Lo sostituiamo con la build RPM ufficiale di
# Mozilla per due motivi pratici:
#  1. Integrazione browser-host nativa (es. 1Password native messaging
#     funziona out-of-the-box; il flatpak richiede workaround sul socket
#     della host integration).
#  2. Allineamento con le system libs (glibc, mesa, ecc.) garantito,
#     niente runtime flatpak che diverge dalla base.
#
# Build-time: il .repo vendored è enabled=0 e --enablerepo=mozilla è il
# runtime override (stesso pattern di gh-cli, docker-ce, vscode).
# Il .repo dichiara priority=10: anche se per errore venissero abilitati
# entrambi (mozilla + fedora) durante un'install futura, dnf5-priorities
# fa vincere Mozilla.
#
# Companion Phase 8 changes (commit successivo, non in questo file):
#  - override di system-flatpaks.list: non auto-installare
#    org.mozilla.firefox al primo boot
#  - estensione flatpak-blocklist: nasconde org.mozilla.firefox dalla
#    GUI (Discover/Bazaar) per evitare reinstall accidentale
#  - system-setup + user-setup hooks: rimuove la flatpak Firefox
#    pre-esistente per chi aggiorna da una bazzite-mx pre-Mozilla-RPM

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

### Section 1: rimuove eventuale firefox del repo Fedora ###
# Bazzite di base non installa firefox come rpm (solo flatpak), ma se
# domani cambia scelta — o se uno dei due pacchetti è presente e
# l'altro no — questo loop cattura comunque il rpm Fedora prima che il
# nostro install Mozilla risolva al provider sbagliato.
# Loop per pacchetto singolo: `dnf5 remove a b` rifiuta l'intera
# operazione se uno dei due non è installato.
for pkg in firefox firefox-langpacks; do
    dnf5 -y remove "$pkg" 2>/dev/null || true
done

### Section 2: install Firefox + langpack italiano dal repo Mozilla ###
# firefox-l10n-it è il langpack italiano nel formato Mozilla
# (firefox-l10n-<lang>). Per estendere la lista delle lingue: aggiungi
# firefox-l10n-<code> alla install qui sotto.
dnf5 -y --enablerepo=mozilla install \
    firefox \
    firefox-l10n-it

echo "::endgroup::"
