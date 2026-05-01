#!/usr/bin/bash
# DX block 10: Container runtime.
# Adds Docker CE (Microsoft repo, enabled=0 + --enablerepo= scope),
# Podman extras (Fedora), and podman-bootc (COPR isolated).
# Style: ported from ublue-os/aurora build_files/dx/00-dx.sh sections.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

# shellcheck disable=SC1091
source /ctx/build_files/shared/copr-helpers.sh

### Section 1: Podman extras (Fedora) ###
dnf5 install -y \
    podman-compose \
    podman-machine \
    podman-tui

### Section 2: Docker CE (repo isolato, enablerepo puntuale) ###
# Add the upstream Docker .repo, immediately neutralise every section
# (enabled=1 → 0) so the repo is never globally active, then install
# with --enablerepo=docker-ce-stable as a runtime-only override.
#
# Why sed and not `dnf5 config-manager setopt`: setopt is a silent
# no-op on .repo files added via `addrepo --from-repofile=URL` (verified
# on dnf5 5.x, Bazzite 44.20260501). It returns 0 and writes nothing,
# which would silently break repo isolation. validate-repos.sh would
# then catch it, but failing-fast at the source is cleaner.
dnf5 config-manager addrepo \
    --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
sed -i 's/^enabled=1/enabled=0/g' /etc/yum.repos.d/docker-ce.repo
dnf5 -y --enablerepo=docker-ce-stable install \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin \
    docker-model-plugin

### Section 3: podman-bootc (COPR isolated) ###
copr_install_isolated gmaglione/podman-bootc podman-bootc

### Section 4: Services ###
systemctl enable docker.socket
systemctl enable podman.socket

echo "::endgroup::"
