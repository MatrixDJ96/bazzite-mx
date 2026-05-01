#!/usr/bin/bash
# DX block 30: IDE.
# Adds Visual Studio Code from the vendored Microsoft RPM repo.
#
# Default user settings for VSCode are shipped via system_files/etc/skel/
# and land in $HOME/.config/Code/User/settings.json on first user creation.
# The settings.json sets only `update.mode=none` so VSCode does not try
# to self-update against a read-only /usr (atomic distro requirement).
# Style choices (font, theme, etc.) are intentionally left to the user
# rather than imposed at distro level. Inspired by bazzite-dx's pattern,
# stripped of opinions.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

### Section 1: Visual Studio Code (vendored repo, enablerepo puntuale) ###
# Repo file is vendored at system_files/etc/yum.repos.d/vscode.repo with
# enabled=0 so it lands disabled via the rsync in build.sh. We use
# --enablerepo=vscode as a runtime-only override during install. Microsoft's
# OpenPGP key (0xBE1229CF) is imported on first dnf5 transaction touching
# the repo; signature verification works on Bazzite 44 (verified
# 2026-05-01). This is stricter than bazzite-dx upstream which sets
# gpgcheck=0 historically; we keep gpgcheck=1.
dnf5 -y --enablerepo=vscode install code

echo "::endgroup::"
