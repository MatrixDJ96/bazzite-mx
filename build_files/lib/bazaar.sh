#!/usr/bin/env bash
# The base's Bazaar blocklist: an id in an unconditional `block:` list keeps the
# Flatpak twin of a shipped RPM out of Bazaar's search and browsing; the
# flatpak CLI is unaffected. Sourced by lib/env.sh.

BAZAAR_BLOCKLIST=/usr/share/ublue-os/bazaar/blocklist.yaml

# bazaar_block_count <app-id> <file>: how many unconditional `block:` lists of
# the YAML blocklist name the id; nothing printed when the file does not parse.
bazaar_block_count() {
    python3 - "$1" "$2" << 'PY'
import sys, yaml
app, path = sys.argv[1:]
with open(path) as f:
    lists = yaml.safe_load(f)["blocklists"]
print(sum((b.get("block") or []).count(app) for b in lists if not b.get("conditions")))
PY
}

# block_in_bazaar <app-id>: one unconditional entry appended after the base's,
# on a fresh inode; the uniqueness is asserted on the parsed file.
block_in_bazaar() {
    local app=$1

    if [ ! -f "$BAZAAR_BLOCKLIST" ]; then
        fail_build "$BAZAAR_BLOCKLIST missing: Bazzite moved Bazaar's blocklist"
    fi

    {
        awk 1 "$BAZAAR_BLOCKLIST"
        printf '\n  - priority: 0\n    block:\n    - %s\n' "$app"
    } > "$BAZAAR_BLOCKLIST.new"
    mv -f "$BAZAAR_BLOCKLIST.new" "$BAZAAR_BLOCKLIST"

    if [ "$(bazaar_block_count "$app" "$BAZAAR_BLOCKLIST")" != 1 ]; then
        fail_build "$BAZAAR_BLOCKLIST: '$app' must be blocked once, unconditionally"
    fi
}
