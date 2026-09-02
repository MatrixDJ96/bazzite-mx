#!/usr/bin/env bash
# VS Code gets the image's default settings when the user has none, and the
# extensions below when they are missing. Every graphical session, from
# ublue-user-setup.service, so a failed install is retried at the next login.
set -euo pipefail

EXTENSIONS=(
    ms-azuretools.vscode-containers
    ms-vscode-remote.remote-containers
    ms-vscode-remote.remote-ssh
)
SKEL=/etc/skel/.config/Code/User/settings.json
SETTINGS=$HOME/.config/Code/User/settings.json
INSTALLED=$HOME/.vscode/extensions/extensions.json

if [ ! -e "$SETTINGS" ] && [ -e "$SKEL" ]; then
    mkdir -p "$(dirname "$SETTINGS")"
    cp "$SKEL" "$SETTINGS"
    echo "bazzite-mx-vscode: settings seeded from $SKEL"
fi

# Ids as VS Code records them; the comparison ignores case, as VS Code does.
have=$(jq -r '.[].identifier.id' "$INSTALLED" 2> /dev/null | tr '[:upper:]' '[:lower:]' || true)
missing=()
for ext in "${EXTENSIONS[@]}"; do
    grep -qx "${ext,,}" <<< "$have" || missing+=("$ext")
done

failed=()
for ext in "${missing[@]}"; do
    echo "bazzite-mx-vscode: installing $ext"
    code --install-extension "$ext" || failed+=("$ext")
done

if [ ${#failed[@]} -gt 0 ]; then
    echo "bazzite-mx-vscode: ERROR: could not install ${failed[*]}; retried at the next login" >&2
    exit 1
fi
echo "bazzite-mx-vscode: ${#missing[@]} extension(s) installed, ${#EXTENSIONS[@]} present"
