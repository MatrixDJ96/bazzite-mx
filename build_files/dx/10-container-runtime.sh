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

### Section 2: Docker CE (vendored repo, enablerepo puntuale) ###
# The repo file is vendored at system_files/etc/yum.repos.d/docker-ce.repo
# with enabled=0 already set, so it lands on disk via the rsync in build.sh
# before this script runs. We only need --enablerepo=docker-ce as a
# runtime-only override during install. No network fetch at build time
# (supply-chain auditability via git diff) and no setopt/sed dance needed.
dnf5 -y --enablerepo=docker-ce install \
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
