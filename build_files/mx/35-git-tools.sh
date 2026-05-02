#!/usr/bin/bash
# MX block 35: Git tools (GUI + system helpers).
# Separate from the IDE block because GitKraken is a Git GUI client,
# not an IDE, and `git-credential-libsecret` is a system git helper used
# by every git client (CLI, IDE, GUI) when paired with a Linux keyring.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

### Section 1: GitKraken (RPM from Axosoft CDN, no yum repo upstream) ###
# Axosoft does not publish a yum repository for GitKraken; only a stable
# direct-RPM URL. We fetch + install in a single dnf5 step. The URL is a
# stable redirect to the latest version, so each image rebuild pulls the
# current GitKraken release — no version pinning by design (closed-source
# desktop app, same trust model as download.docker.com for Phase 2).
# Trade-off vs vendored .repo: there is no auditable .repo file in git for
# this URL, but Axosoft does not provide one upstream. The dependency
# footprint is zero (Electron app self-bundled, ~663 MiB installed).
dnf5 -y install https://release.gitkraken.com/linux/gitkraken-amd64.rpm

### Section 2: git-credential-libsecret (Fedora) ###
# Plugs `git` into the Linux keyring (KDE Wallet / GNOME Keyring) so
# every git client — CLI, VSCode, GitKraken — picks up cached HTTPS
# credentials transparently. Aurora ships this in their base layer
# (build_files/base/01-packages.sh:84); Bazzite base does not. Adding
# it here brings the Aurora "secure-by-default" git UX to bazzite-mx.
dnf5 -y install git-credential-libsecret

echo "::endgroup::"
