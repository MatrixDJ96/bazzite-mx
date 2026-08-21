#!/usr/bin/bash
# MX block 65: Sunshine self-hosted game-streaming host (Moonlight server).
#
# Installs Sunshine as a system RPM from the community `pvermeer/sunshine`
# COPR via the isolated-COPR pattern — the "Layer from Community COPR"
# method in https://docs.bazzite.gg/Advanced/sunshine/. The COPR is
# maintained explicitly for Fedora with a tested package for every major
# Fedora/Bazzite release. Shipping the RPM avoids the per-user cost of
# Bazzite's flatpak/brew `setup-sunshine` paths.
#
# The RPM (spec: github.com/PVermeer/copr_sunshine) ships
# `%caps(cap_sys_admin,cap_sys_nice+p)` on /usr/bin/sunshine — KMS-based
# capture works out of the box — plus the user unit
# `app-dev.lizardbyte.app.Sunshine.service` with the spec-guaranteed alias
# `sunshine.service` and the uinput udev rules. The rpm name is lowercase
# `sunshine`, so `rpm -q sunshine` matches.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

# shellcheck disable=SC1091
source /ctx/build_files/shared/copr-helpers.sh

### Section 1: install Sunshine from pvermeer/sunshine (isolated COPR) ###
copr_install_isolated "pvermeer/sunshine" "sunshine"

### Section 2: keep the user service disabled (opt-in) ###
# Defense-in-depth against a preset enabling the unit: the package's
# `%systemd_user_post` honours presets, and its drop-in adds extra
# [Install] targets (gnome-session, xdg-desktop-autostart). The user
# opts in via `ujust setup-sunshine enable`.
systemctl --global disable app-dev.lizardbyte.app.Sunshine.service

### Section 3: drop Bazzite's "switch-to-brew" announcement nag ###
# The nag tells users Sunshine will be removed from base Bazzite and must
# be reinstalled via Bazzite Portal; misleading with our RPM integration.
NAG=/usr/share/ublue-os/announcements/sunshine-brew.msg.json
[ -f "$NAG" ] && rm -f "$NAG"

echo "::endgroup::"
