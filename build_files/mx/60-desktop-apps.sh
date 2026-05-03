#!/usr/bin/bash
# MX block 60: Desktop GUI applications.
# Tools che non sono né IDE (Phase 4) né dev-CLI (Phase 6) — utility
# desktop di uso quotidiano.
#
# gparted:
#   Bazzite rimuove `kde-partitionmanager` dalla loro KDE base
#   (commit 378e524a, Containerfile:421 della loro repo). Senza tool
#   GUI di partitioning, le operazioni su dischi esterni / preparazione
#   chiavette / resize partizioni dual-boot diventano scomode.
#   gparted lo rimpiazza con il classico tool universale (~9 MiB).
#   Provenance: AmyOS lo installa nella loro lista DX-style
#   (`install-apps.sh:22`). Bazzite stesso lo installa solo nell'hook
#   dell'installer ISO (`titanoboa_hook_postrootfs.sh:313`) — non
#   nell'immagine bootc deployment.
#
# ptyxis:
#   Terminale GTK4 container-aware (Distrobox/Toolbox/Podman nativi).
#   Bazzite l'aveva adottato come default su KDE poi rimosso (commit
#   378e524a, motivo: "in preparation for switching back to Konsole
#   w/ Container support" — Konsole 26.04 ha integrazione container).
#   Aurora-DX continua a shipparlo + replica tutti i sed/.desktop +
#   un loro shim `kde-ptyxis`.
#
#   Noi facciamo BARE INSTALL: nessun shim, nessuna modifica a
#   .desktop o dbus service. Konsole resta il default terminal di
#   KDE; Ptyxis è un secondo terminale opt-in lanciabile dal menu.
#   Razionale: gli scopi del shim `kde-ptyxis` (-e flag translation,
#   --new-window per "Open Terminal Here" da Dolphin, GTK_IM_MODULE)
#   si attivano solo quando Ptyxis è il default terminal — scenario
#   che non perseguiamo. Evita ~25 righe di maintenance debt che
#   Bazzite stesso ha esplicitamente abbandonato.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

dnf5 -y install \
    gparted \
    ptyxis

echo "::endgroup::"
