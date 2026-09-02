#!/usr/bin/env bash
# VS Code gets the image's default settings when the user has none, and the
# extensions below when they are missing. Every graphical session, from
# ublue-user-setup.service, so a failed install is retried at the next login.
#
# Usage: 11-bazzite-mx-vscode-extensions.sh   (as the user; ublue-user-setup
#                                              runs it)
#   The smoke test puts a stub `code` first on PATH and points HOME at a
#   fixture home.
# Output: `bazzite-mx-vscode: …` lines, the last one the count installed and
#   present (tests/30-ide.sh reads it).
# Exit status: 0 done; 1 an install failed, the extensions named in a
#   `bazzite-mx-vscode: ERROR: …` line on stderr.
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
    if [ -e "$SETTINGS" ] || [ ! -e "$SKEL" ]; then
        return 0
    fi

    mkdir -p "$(dirname "$SETTINGS")"
    cp "$SKEL" "$SETTINGS"
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

install_missing_extensions() {
    local extension

    for extension in "${MISSING[@]}"; do
        echo "bazzite-mx-vscode: installing $extension"
        if ! code --install-extension "$extension"; then
            FAILED+=("$extension")
        fi
    done
}

# --- main ---------------------------------------------------------------------

main() {
    seed_settings_from_skel

    find_missing_extensions
    install_missing_extensions

    if [ ${#FAILED[@]} -gt 0 ]; then
        echo "bazzite-mx-vscode: ERROR: could not install ${FAILED[*]};" \
            "retried at the next login" >&2
        exit 1
    fi

    echo "bazzite-mx-vscode: ${#MISSING[@]} extension(s) installed, ${#EXTENSIONS[@]} present"
}

main "$@"
