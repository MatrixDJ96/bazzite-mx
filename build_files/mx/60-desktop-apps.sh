#!/usr/bin/bash
# MX block 60: daily-use desktop GUI applications.
#
# gparted — GUI partitioning tool (Bazzite ships no GUI partition tool
#   in the bootc deployment image).
# ptyxis — GTK4 container-aware terminal, opt-in. Bare install: no shim,
#   no .desktop / dbus edits. Konsole stays the KDE default; Ptyxis is a
#   second terminal launchable from the menu (the `kde-ptyxis` shim only
#   matters when Ptyxis is the default terminal, which we don't pursue).

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

dnf5 -y install \
    gparted \
    ptyxis

echo "::endgroup::"
