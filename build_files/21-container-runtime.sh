#!/usr/bin/env bash
# Container runtime: Docker CE from the vendored repository, key asserted
# first, beside the base's podman, plus the podman tools the base leaves out.
# Both daemons stay socket-activated.
#
# Usage: run by build.sh; no arguments.
# Writes: the Docker CE and podman packages; docker.socket and podman.socket
#   enabled.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

assert_key_fingerprint /etc/pki/rpm-gpg/RPM-GPG-KEY-docker-ce
install_from_repo docker-ce-stable \
    containerd.io \
    docker-buildx-plugin \
    docker-ce \
    docker-ce-cli \
    docker-compose-plugin

# The docker-ce %post creates the group; a host's boot hook adds the users.
if ! grep -q '^docker:' /etc/group; then
    fail_build "docker group not created by the docker-ce %post"
fi

dnf5 -y install \
    bcvk \
    podman-compose \
    podman-machine \
    podman-tui

systemctl enable docker.socket
systemctl enable podman.socket

docker_version=$(rpm -q --qf '%{VERSION}' docker-ce)
podman_version=$(rpm -q --qf '%{VERSION}' podman)
log "container-runtime: docker $docker_version, podman $podman_version"
