#!/usr/bin/bash
# Final cleanup before bootc lint + image build completion.
# Ported from ublue-os/aurora, adapted for Bazzite (no /opt symlink fixup
# because Bazzite already manages /opt differently).

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# Revert dnf cache to default
dnf config-manager setopt keepcache=0 || true

# Clear any versionlock entries (idempotent)
dnf versionlock clear 2>/dev/null || true

# Prevent Fedora flatpak repos from being added (idempotent, safe if absent)
if [ -f /usr/lib/systemd/system/flatpak-add-fedora-repos.service ]; then
    systemctl mask flatpak-add-fedora-repos.service || true
    rm -f /usr/lib/systemd/system/flatpak-add-fedora-repos.service
fi

# Strip stray .gitkeep markers
rm -f /.gitkeep

# Selective /var cleanup (preserve cache; cache dir is bind-mounted at build time)
find /var/* -maxdepth 0 -type d ! -name cache -exec rm -fr {} \;
rm -rf /tmp/*
mkdir -p /var/tmp

echo "::endgroup::"
