#!/usr/bin/bash
# MX block 60: Desktop GUI applications.
# Tools that fit neither in the Phase 4 IDE block nor in the Phase 6
# dev-CLI block — daily-use desktop utilities.
#
# gparted:
#   Bazzite removes `kde-partitionmanager` from their KDE base
#   (commit 378e524a, Containerfile:421 in their repo). Without a GUI
#   partitioning tool, daily disk operations (USB stick prep,
#   external-drive formatting, dual-boot partition resizes) become
#   awkward. gparted replaces it with the classic universal tool
#   (~9 MiB).
#   Provenance: AmyOS ships it in their DX-style list
#   (`install-apps.sh:22`). Bazzite itself only installs it in the
#   ISO installer hook (`titanoboa_hook_postrootfs.sh:313`) — not
#   in the bootc deployment image.
#
# ptyxis:
#   GTK4 container-aware terminal (native Distrobox/Toolbox/Podman
#   integration). Bazzite adopted it as KDE default, then removed it
#   (commit 378e524a, rationale: "in preparation for switching back
#   to Konsole w/ Container support" — Konsole 26.04 has container
#   integration). Aurora-DX still ships it plus replicates the
#   .desktop / dbus seds and a custom `kde-ptyxis` shim.
#
#   We deliberately do a BARE INSTALL: no shim, no .desktop or dbus
#   service edits. Konsole stays the KDE default terminal; Ptyxis is
#   a second opt-in terminal launchable from the menu. Rationale:
#   the `kde-ptyxis` shim's purposes (-e flag translation,
#   --new-window for Dolphin's "Open Terminal Here", GTK_IM_MODULE)
#   only kick in when Ptyxis IS the default terminal — a path we
#   don't pursue. Avoids ~25 lines of maintenance debt that Bazzite
#   itself explicitly abandoned.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

dnf5 -y install \
    gparted \
    ptyxis

echo "::endgroup::"
