#!/usr/bin/bash
# MX block 30: IDE.
# Adds Visual Studio Code from the vendored Microsoft RPM repo.
#
# Default VSCode settings ship via system_files/etc/skel/ and land in
# $HOME/.config/Code/User/settings.json on first user creation; they set
# only `update.mode=none` so VSCode doesn't self-update against a
# read-only /usr.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

### Section 1: Visual Studio Code (vendored repo, scoped --enablerepo) ###
# Repo file (system_files/etc/yum.repos.d/vscode.repo, enabled=0) lands
# disabled via the rsync in build.sh; --enablerepo=vscode is the
# runtime-only override. gpgcheck=1 (Microsoft's key is imported on the
# first dnf5 transaction touching the repo).
dnf5 -y install --enablerepo=vscode code

echo "::endgroup::"
