#!/usr/bin/bash
# MX block 10: Container runtime.
# Adds Docker CE (vendored repo, enabled=0 + --enablerepo= scope),
# Podman extras (Fedora) and bcvk (Fedora).

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

### Section 1: Podman extras (Fedora) ###
dnf5 -y install \
    podman-compose \
    podman-machine \
    podman-tui

### Section 2: Docker CE (vendored repo, scoped --enablerepo) ###
# The repo file (system_files/etc/yum.repos.d/docker-ce.repo, enabled=0)
# lands on disk via the rsync in build.sh; --enablerepo=docker-ce is the
# runtime-only override during install.
dnf5 -y install --enablerepo=docker-ce \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin \
    docker-model-plugin

### Section 3: bcvk (Fedora) ###
# Runs bootable container images as VMs, the job podman-bootc used to do
# here. Upstream archived podman-bootc in favour of bcvk
# (bootc-dev/podman-bootc#134) and aurora made the same swap in 7e31b429;
# our copy was still an fc43 build from 2025-08-05 out of the fedora-44
# chroot of a COPR nobody rebuilds. bcvk is a plain Fedora package (0.18.0
# in updates, MEASURED 2026-09-01), so the COPR goes with it -- and with it
# the `qemu` metapackage podman-bootc hard-required, which pulled every
# per-arch system emulator into the image (retired gotcha #23; bcvk asks
# for qemu-img, qemu-kvm and virtiofsd only).
dnf5 -y install bcvk

### Section 4: Services ###
systemctl enable docker.socket
systemctl enable podman.socket

echo "::endgroup::"
