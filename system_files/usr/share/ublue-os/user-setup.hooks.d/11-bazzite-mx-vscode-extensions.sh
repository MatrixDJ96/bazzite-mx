#!/usr/bin/env bash
# VS Code gets the image's default settings when the user has none, and the
# extensions below when they are missing. Every graphical session, from
# ublue-user-setup.service, so a failed install is retried at the next login;
# with extensions missing it first waits up to 60 s for a connection.
#
# Usage: 11-bazzite-mx-vscode-extensions.sh   (as the user; ublue-user-setup
#                                              runs it)
#   The smoke test puts a stub `code` and a stub `nm-online` first on PATH
#   and points HOME at a fixture home.
# Output: `bazzite-mx-vscode: …` lines, the last one the count installed and
#   present (tests/30-ide.sh reads it).
# Exit status: 0 done; 1 the settings could not be seeded or an install
#   failed, the file or the extensions named in a `bazzite-mx-vscode: ERROR: …`
#   line on stderr.
set -euo pipefail

EXTENSIONS=(
    ms-azuretools.vscode-containers
    ms-vscode-remote.remote-containers
    ms-vscode-remote.remote-ssh
)
SKEL=/etc/skel/.config/Code/User/settings.json
SETTINGS=$HOME/.config/Code/User/settings.json
INSTALLED=$HOME/.vscode/extensions/extensions.json

# Filled by find_missing_extensions and install_missing_extensions.
MISSING=()
FAILED=()

# --- settings -----------------------------------------------------------------

seed_settings_from_skel() {
    if [ -e "$SETTINGS" ]; then
        return 0
    fi

    if [ ! -e "$SKEL" ]; then
        return 0
    fi

    # `set -e` alone would leave no journal line (docs/conventions.md § Boot
    # hooks): a ~/.config that is a file, or a read-only home, is named.
    # Written beside and renamed, so a copy cut short by a full home leaves
    # no empty file for the next login to take as the user's settings.
    if ! mkdir -p "$(dirname "$SETTINGS")" 2> /dev/null \
        || ! cp "$SKEL" "$SETTINGS.new" 2> /dev/null \
        || ! mv -f "$SETTINGS.new" "$SETTINGS" 2> /dev/null; then
        rm -f "$SETTINGS.new"
        echo "bazzite-mx-vscode: ERROR: cannot seed $SETTINGS from $SKEL" >&2
        exit 1
    fi

    echo "bazzite-mx-vscode: settings seeded from $SKEL"
}

# --- extensions ---------------------------------------------------------------

# installed_extension_ids: one id per line, lower-cased, as VS Code records
# them; empty when VS Code has never run.
installed_extension_ids() {
    jq -r '.[].identifier.id' "$INSTALLED" 2> /dev/null | tr '[:upper:]' '[:lower:]' || true
}

# The comparison ignores case, as VS Code does.
find_missing_extensions() {
    local installed extension

    installed=$(installed_extension_ids)

    for extension in "${EXTENSIONS[@]}"; do
        if ! grep -qx "${extension,,}" <<< "$installed"; then
            MISSING+=("$extension")
        fi
    done
}

# count_present_extensions: how many of the three VS Code records now,
# read again after the installs: a `code` that exits 0 and records
# nothing is not a present extension.
count_present_extensions() {
    local installed extension count=0

    installed=$(installed_extension_ids)

    for extension in "${EXTENSIONS[@]}"; do
        if grep -qx "${extension,,}" <<< "$installed"; then
            count=$((count + 1))
        fi
    done

    echo "$count"
}

install_missing_extensions() {
    local extension

    for extension in "${MISSING[@]}"; do
        echo "bazzite-mx-vscode: installing $extension"

        if ! code --disable-telemetry --install-extension "$extension"; then
            FAILED+=("$extension")
        fi
    done
}

# --- main ---------------------------------------------------------------------

main() {
    seed_settings_from_skel

    find_missing_extensions

    # The unit's After=network-online.target names a unit the user manager
    # lacks, so a session opened at boot starts this before the network; a
    # timeout installs anyway and the failures go to the next login.
    if [ ${#MISSING[@]} -gt 0 ]; then
        nm-online -q -t 60 || true
    fi

    install_missing_extensions

    if [ ${#FAILED[@]} -gt 0 ]; then
        echo "bazzite-mx-vscode: ERROR: could not install ${FAILED[*]};" \
            "retried at the next login" >&2
        exit 1
    fi

    echo "bazzite-mx-vscode: ${#MISSING[@]} extension(s) installed," \
        "$(count_present_extensions) present"
}

main "$@"
