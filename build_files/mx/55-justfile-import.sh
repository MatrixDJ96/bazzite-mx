#!/usr/bin/bash
# MX block 55: register the MX justfile in Bazzite's master ujust file.
#
# Bazzite's master /usr/share/ublue-os/justfile uses explicit `import`
# directives per `.just`; 95-bazzite-mx.just is NOT loaded by `ujust`
# until its import is added there. Idempotent append at the end of the
# master, preserving all upstream imports.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

MASTER=/usr/share/ublue-os/justfile
IMPORT_LINE='import "/usr/share/ublue-os/just/95-bazzite-mx.just"'

if [ ! -f "$MASTER" ]; then
    echo "FAIL: $MASTER not found (did Bazzite change layout?)"
    exit 1
fi

# Idempotent: append only if the line isn't already there.
if grep -qxF "$IMPORT_LINE" "$MASTER"; then
    echo "Import line already present in $MASTER, skipping."
else
    {
        echo ""
        echo "# bazzite-mx custom recipes"
        echo "$IMPORT_LINE"
    } >> "$MASTER"
    echo "Import line appended to $MASTER."
fi

echo "::endgroup::"
