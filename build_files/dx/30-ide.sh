#!/usr/bin/bash
# DX block 30: IDE / GUI git client.
# Adds Visual Studio Code (Microsoft RPM repo, vendored) and GitKraken
# (Axosoft RPM, fetched at build time — no upstream yum repo exists).

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

### Section 2: GitKraken (RPM from Axosoft CDN, no yum repo upstream) ###
# Axosoft does not publish a yum repository for GitKraken; only a stable
# direct-RPM URL. We fetch + install in a single dnf5 step. The URL is a
# stable redirect to the latest version, so each image rebuild pulls the
# current GitKraken release — no version pinning by design (closed-source
# desktop app, no security downside since we trust HTTPS to release.gitkraken.com
# the same way we trust download.docker.com for Phase 2).
#
# Trade-off vs vendored .repo: there is no auditable .repo file in git for
# this URL, but Axosoft does not provide one upstream. The dependency
# footprint is zero (Electron app self-bundled, ~663 MiB installed).
dnf5 -y install https://release.gitkraken.com/linux/gitkraken-amd64.rpm

echo "::endgroup::"
