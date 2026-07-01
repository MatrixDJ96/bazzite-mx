#!/usr/bin/bash
# user-setup hook: pre-install the 3 Microsoft VSCode extensions for
# container/remote workflow (Distrobox, Docker, SSH), and seed the
# default settings.json from /etc/skel for existing accounts that
# /etc/skel doesn't reach.
#
# Versioned: bumping the number below re-runs the hook on next login.

set -euo pipefail

# shellcheck disable=SC1091
source /usr/lib/ublue/setup-services/libsetup.sh

version-script vscode-extensions user 1 || exit 0

# If the user has no VSCode settings.json yet, copy our default from
# /etc/skel. Guard the source path too: a missing skel file would
# otherwise abort the hook (set -e) before the install lines, and
# libsetup.sh has already written state → no retry, ever.
if [ ! -e "$HOME/.config/Code/User/settings.json" ] && \
   [ -e /etc/skel/.config/Code/User/settings.json ]; then
    mkdir -p "$HOME/.config/Code/User"
    cp -f /etc/skel/.config/Code/User/settings.json "$HOME/.config/Code/User/settings.json"
fi

# 3 Microsoft container/remote workflow extensions.
#
# `|| true`: the VSCode marketplace can be transiently unreachable. Without
# it, set -e would abort the hook, but libsetup.sh has already written the
# state file before the body — so a failed install would become permanent.
code --install-extension ms-vscode-remote.remote-containers || true
code --install-extension ms-vscode-remote.remote-ssh || true
code --install-extension ms-azuretools.vscode-containers || true

echo "user vscode-extensions hook complete."
