#!/usr/bin/bash
# MX block 55: register the MX justfile in Bazzite's master ujust file.
#
# Bazzite's `ujust` is a wrapper around `just` that uses the master file
# `/usr/share/ublue-os/justfile` with explicit `import` directives for
# each registered `.just` (see the `import "/usr/share/ublue-os/just/
# 8X-bazzite-*.just"` lines in the file). Our `95-bazzite-mx.just`,
# even when shipped under `/usr/share/ublue-os/just/`, is NOT loaded
# by `ujust --list` or `ujust install-<x>` until we add the import
# to the master.
#
# Drift-tolerant strategy: idempotent append at the end of the master,
# preserving all upstream imports (which may change over time). The
# upstream import block ends with a blank line; we append after it.

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
        echo "# bazzite-mx custom recipes (Phase 8)"
        echo "$IMPORT_LINE"
    } >> "$MASTER"
    echo "Import line appended to $MASTER."
fi

echo "::endgroup::"
