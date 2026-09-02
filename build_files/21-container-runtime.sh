#!/usr/bin/env bash
# Container runtime: Docker CE from the vendored repository, key asserted
# first, beside the base's podman, plus the podman tools the base leaves out.
# Both daemons stay socket-activated.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

assert_key_fingerprint /etc/pki/rpm-gpg/RPM-GPG-KEY-docker-ce
install_from_repo docker-ce-stable \
    containerd.io \
    docker-buildx-plugin \
    docker-ce \
    docker-ce-cli \
    docker-compose-plugin

grep -q '^docker:' /etc/group || die "docker group not created by the docker-ce %post"

dnf5 -y install \
    bcvk \
    podman-compose \
    podman-machine \
    podman-tui

systemctl enable docker.socket
systemctl enable podman.socket

log "container-runtime: docker $(rpm -q --qf '%{VERSION}' docker-ce), podman $(rpm -q --qf '%{VERSION}' podman)"
