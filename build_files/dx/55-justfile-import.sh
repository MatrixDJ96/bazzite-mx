#!/usr/bin/bash
# DX block 55: registra il justfile MX nel master ujust di Bazzite.
#
# Bazzite ujust è un wrapper di `just` che usa il master file
# `/usr/share/ublue-os/justfile` con `import` espliciti per ciascun
# `.just` registrato (vedi le righe `import "/usr/share/ublue-os/just/
# 8X-bazzite-*.just"` nel file). Il nostro `95-bazzite-mx.just`,
# anche se shipped in `/usr/share/ublue-os/just/`, non viene caricato
# da `ujust --list` o `ujust install-<x>` finché non aggiungiamo
# l'import al master.
#
# Strategia drift-tolerant: append idempotente alla coda del master,
# preservando tutti gli import upstream (potrebbe cambiare nel tempo).
# Il blocco import upstream è seguito da una riga vuota; appendiamo
# in coda al file.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

MASTER=/usr/share/ublue-os/justfile
IMPORT_LINE='import "/usr/share/ublue-os/just/95-bazzite-mx.just"'

if [ ! -f "$MASTER" ]; then
    echo "FAIL: $MASTER non trovato (Bazzite ha cambiato struttura?)"
    exit 1
fi

# Idempotente: append solo se la riga non c'è già.
if grep -qxF "$IMPORT_LINE" "$MASTER"; then
    echo "Import line already present in $MASTER, skipping."
else
    {
        echo ""
        echo "# bazzite-mx custom recipes (Phase 8)"
        echo "$IMPORT_LINE"
    } >> "$MASTER"
    echo "Import line appended to $MASTER."
fi

echo "::endgroup::"
