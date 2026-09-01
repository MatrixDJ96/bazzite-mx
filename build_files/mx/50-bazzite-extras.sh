#!/usr/bin/bash
# MX block 50: Bazzite-DX gems (curated subset).
#   * `ccache` — compiler cache; pays off when a new kernel triggers
#     an akmod recompile.
#   * `ublue-setup-services` (COPR ublue-os/packages) — Universal Blue's
#     system / user / privileged setup-hooks framework, providing
#     JSON-based version tracking for first-boot setup scripts.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

# shellcheck disable=SC1091
source /ctx/build_files/shared/copr-helpers.sh

### Section 1: ccache (Fedora) ###
dnf5 -y install ccache

### Section 2: ublue-setup-services (COPR isolated) ###
# Provides:
#   /usr/lib/systemd/system/ublue-system-setup.service     (root, oneshot at boot)
#   /usr/lib/systemd/user/ublue-user-setup.service         (user, first login)
#   /usr/libexec/ublue-{system,user,privileged}-setup      (dispatchers)
#   /usr/lib/ublue/setup-services/libsetup.sh              (version-script helper)
#   /usr/bin/sb-key-notify + check-sb-key.service          (Secure Boot key change)
copr_install_isolated "ublue-os/packages" "ublue-setup-services"

### Section 3: enable system + user setup dispatchers ###
# The package does not ship a systemd-preset, so we enable the units
# explicitly. Hooks live under /usr/share/ublue-os/{system,user}-setup.hooks.d/
# (shipped via system_files/).
systemctl enable ublue-system-setup.service
systemctl --global enable ublue-user-setup.service

echo "::endgroup::"
