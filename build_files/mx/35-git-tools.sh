#!/usr/bin/bash
# MX block 35: Git tools (GUI + system helpers).
# Separate from the IDE block because GitKraken is a Git GUI client,
# not an IDE, and `git-credential-libsecret` is a system git helper used
# by every git client (CLI, IDE, GUI) when paired with a Linux keyring.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

### Section 1: GitKraken (RPM from Axosoft CDN, no yum repo upstream) ###
# Axosoft publishes no yum repository and no signed RPM: the stable URL
# redirects to a versioned path (release.gitkraken.dev/…/<version>/<token>/)
# whose content changes on every GitKraken release, and the package carries
# no GPG signature (`rpm -qp --qf '%{SIGPGP:pgpsig}'` → none, MEASURED
# 2026-09-01 on 12.4.0) — unlike download.docker.com, where docker-ce.repo
# has gpgcheck=1. The trust anchor is therefore this repo: version and
# sha256 are pinned here and checked before dnf5 touches the file, so a
# swapped upstream artefact fails the build instead of shipping. Bumping the
# pin is a reviewed change (upstream-refresh round), never a silent re-fetch.
# Zero dependency footprint (self-bundled Electron, ~663 MiB).
GITKRAKEN_VERSION=12.4.0
GITKRAKEN_SHA256=68b7bdac404b34a2a642d65161514025f15bf97b5f54099ce97d27dcdda6068d
curl -fsSL -o /tmp/gitkraken-amd64.rpm https://release.gitkraken.com/linux/gitkraken-amd64.rpm
echo "${GITKRAKEN_SHA256}  /tmp/gitkraken-amd64.rpm" | sha256sum -c -
rpm -qp --qf '%{VERSION}\n' /tmp/gitkraken-amd64.rpm | grep -qxF "${GITKRAKEN_VERSION}"
dnf5 -y install /tmp/gitkraken-amd64.rpm
rm -f /tmp/gitkraken-amd64.rpm

### Section 2: git-credential-libsecret (Fedora) ###
# Plugs `git` into the Linux keyring (KDE Wallet / GNOME Keyring) so
# every git client — CLI, VSCode, GitKraken — picks up cached HTTPS
# credentials transparently. Aurora ships this in their base layer
# (build_files/base/01-packages.sh:84); Bazzite base does not. Adding
# it here brings the Aurora "secure-by-default" git UX to bazzite-mx.
dnf5 -y install git-credential-libsecret

echo "::endgroup::"
