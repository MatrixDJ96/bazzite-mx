#!/usr/bin/bash
# user-setup hook: pre-installa le 3 VSCode extension Microsoft per
# container/remote workflow (Distrobox, Docker, SSH).
#
# Lista identica a Bazzite-DX (`11-vscode-extensions.sh`) e Aurora-DX
# (`/usr/libexec/aurora-dx-user-vscode`) — i due upstream hanno
# convergito indipendentemente sulle stesse 3 estensioni first-party
# Microsoft. Zero bias di linguaggio (no Prettier/ESLint/GitLens).
#
# Copy del settings.json default da /etc/skel se l'utente non ne ha uno:
# copre il gotcha #4 (skel non raggiunge utenti già esistenti — il hook
# lo forza al primo login post-install della distro).
#
# Versioned: bump del numero qui sotto rigira l'hook al login successivo.

set -euo pipefail

# shellcheck disable=SC1091
source /usr/lib/ublue/setup-services/libsetup.sh

version-script vscode-extensions user 1 || exit 0

# Se l'utente non ha ancora un settings.json di VSCode, ci copia il
# nostro default da /etc/skel (Bazzite-DX-style fallback).
# Guard anche sulla source path: senza, una rimozione futura del file
# in /etc/skel farebbe abortire il hook (set -e) PRIMA delle install,
# e libsetup.sh ha già scritto lo state → niente retry mai più.
if [ ! -e "$HOME/.config/Code/User/settings.json" ] && \
   [ -e /etc/skel/.config/Code/User/settings.json ]; then
    mkdir -p "$HOME/.config/Code/User"
    cp -f /etc/skel/.config/Code/User/settings.json "$HOME/.config/Code/User/settings.json"
fi

# 3 extension Microsoft container/remote workflow.
# Lista convergente Aurora-DX + Bazzite-DX (verificato 2026-05-03).
#
# `|| true`: il marketplace VSCode può essere transientemente unreachable
# (rete metered, downtime Microsoft). Senza, set -e aborta il hook ma
# libsetup.sh ha già scritto lo state file PRIMA del body — quindi una
# install fallita diventerebbe permanente. Failure di rete è benigna
# (eccezione legittima alla regola "no || true" di conventions.md).
code --install-extension ms-vscode-remote.remote-containers || true
code --install-extension ms-vscode-remote.remote-ssh || true
code --install-extension ms-azuretools.vscode-containers || true

echo "user vscode-extensions hook complete."
