#!/usr/bin/bash
# MX block 50: Bazzite-DX gems (curated subset).
# We import only the bits that match concrete bazzite-mx use cases:
#
#   * `ccache` — compiler cache. Bazzite base ships gcc/gcc-c++/make
#     for kernel module rebuilds (akmod), so ccache pays off any time
#     a new kernel triggers a recompile. ~1 MiB.
#
#   * `ublue-setup-services` (COPR ublue-os/packages) — Universal Blue's
#     system / user / privileged setup-hooks framework. Adopted only by
#     bazzite-dx in the wider ublue ecosystem (Aurora, Aurora-DX, AmyOS,
#     Bazzite base do not use it as of 2026-05-02), but it solves a
#     concrete problem cleanly: scalable JSON-based version tracking
#     for first-boot setup scripts. We migrate `bazzite-mx-groups` to
#     a system-setup hook in this same commit.
#
# Skipped from the original Phase 7 list (per user decision):
# python3-ramalama, restic, rclone, zsh, tiptop, git-subtree —
# specific use cases none of which apply here. usbmuxd already in base.

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
# explicitly. Hooks live under /usr/share/ublue-os/{system,user,privileged}-setup.hooks.d/
# (shipped via system_files/).
systemctl enable ublue-system-setup.service
systemctl --global enable ublue-user-setup.service

echo "::endgroup::"
