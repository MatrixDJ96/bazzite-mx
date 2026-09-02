#!/usr/bin/env bash
# The Konsole shortcuts and the PowerShell profile of /etc/skel reach an
# account that predates the image: each file is copied when the user has
# none, and a file the user already has is left alone. Every graphical
# session, from ublue-user-setup.service, so a home created later is reached
# at its first login.
#
# Usage: 12-bazzite-mx-copy-paste.sh   (as the user; ublue-user-setup runs it)
#   The smoke test points HOME at a fixture home.
# Output: `bazzite-mx-copy-paste: …` lines, the last one the count seeded and
#   the count present in HOME (tests/45-kde-defaults.sh reads it).
# Exit status: 0 done; 1 a copy failed, the file named in a
#   `bazzite-mx-copy-paste: ERROR: …` line on stderr.
set -euo pipefail

SKEL=/etc/skel
FILES=(
    .local/share/kxmlgui5/konsole/sessionui.rc
    .config/powershell/profile.ps1
)

# Filled by seed_missing_files.
SEEDED=()
FAILED=()

# --- seeding ------------------------------------------------------------------

# seed_file <relative path>: the skel copy lands in HOME when HOME has none.
seed_file() {
    local file=$1

    if [ -e "$HOME/$file" ]; then
        return 0
    fi

    echo "bazzite-mx-copy-paste: seeding $file from $SKEL"

    # Written beside and renamed, so a copy cut short by a full home leaves
    # no empty file for the next login to count as present.
    if mkdir -p "$(dirname "$HOME/$file")" 2> /dev/null \
        && cp "$SKEL/$file" "$HOME/$file.new" 2> /dev/null \
        && mv -f "$HOME/$file.new" "$HOME/$file" 2> /dev/null; then
        SEEDED+=("$file")
    else
        rm -f "$HOME/$file.new"
        FAILED+=("$file")
    fi
}

seed_missing_files() {
    local file

    for file in "${FILES[@]}"; do
        seed_file "$file"
    done
}

count_present_files() {
    local file count=0

    for file in "${FILES[@]}"; do
        if [ -e "$HOME/$file" ]; then
            count=$((count + 1))
        fi
    done

    echo "$count"
}

# --- main ---------------------------------------------------------------------

main() {
    seed_missing_files

    if [ ${#FAILED[@]} -gt 0 ]; then
        echo "bazzite-mx-copy-paste: ERROR: could not seed ${FAILED[*]};" \
            "retried at the next login" >&2
        exit 1
    fi

    echo "bazzite-mx-copy-paste: ${#SEEDED[@]} file(s) seeded, $(count_present_files) present"
}

main "$@"
