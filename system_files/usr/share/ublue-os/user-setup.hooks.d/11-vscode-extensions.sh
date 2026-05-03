#!/usr/bin/bash
# user-setup hook: pre-install the 3 Microsoft VSCode extensions for
# container/remote workflow (Distrobox, Docker, SSH).
#
# Same list as Bazzite-DX (`11-vscode-extensions.sh`) and Aurora-DX
# (`/usr/libexec/aurora-dx-user-vscode`) — both upstreams independently
# converged on the same 3 first-party Microsoft extensions. Zero
# language bias (no Prettier/ESLint/GitLens).
#
# Copy the default settings.json from /etc/skel if the user doesn't
# have one: covers gotcha #4 (skel doesn't reach existing accounts —
# the hook forces it on first login after the distro change).
#
# Versioned: bumping the number below re-runs the hook on next login.

set -euo pipefail

# shellcheck disable=SC1091
source /usr/lib/ublue/setup-services/libsetup.sh

version-script vscode-extensions user 1 || exit 0

# If the user has no VSCode settings.json yet, copy our default from
# /etc/skel (Bazzite-DX-style fallback). Guard the source path too:
# without it, a future removal of the skel file would abort the hook
# (set -e) BEFORE the install lines, and libsetup.sh has already
# written state → no retry, ever.
if [ ! -e "$HOME/.config/Code/User/settings.json" ] && \
   [ -e /etc/skel/.config/Code/User/settings.json ]; then
    mkdir -p "$HOME/.config/Code/User"
    cp -f /etc/skel/.config/Code/User/settings.json "$HOME/.config/Code/User/settings.json"
fi

# 3 Microsoft container/remote workflow extensions.
# Convergent list across Aurora-DX + Bazzite-DX (verified 2026-05-03).
#
# `|| true`: the VSCode marketplace can be transiently unreachable
# (metered network, Microsoft downtime). Without it, set -e would
# abort the hook but libsetup.sh has already written the state file
# BEFORE the body — so a failed install would become permanent.
# Network failure is benign (legitimate exception to conventions.md's
# "no || true" rule).
code --install-extension ms-vscode-remote.remote-containers || true
code --install-extension ms-vscode-remote.remote-ssh || true
code --install-extension ms-azuretools.vscode-containers || true

echo "user vscode-extensions hook complete."
