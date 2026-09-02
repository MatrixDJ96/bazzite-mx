#!/usr/bin/env bash
# Command-line tools from Fedora, none of them in the base. Fedora's shfmt is
# the release CI and the edit hook format with, so the image, the hook and CI
# agree on the formatter (docs/conventions.md).
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

dnf5 -y install \
    ShellCheck \
    android-tools \
    bcc \
    bcc-tools \
    bpftop \
    bpftrace \
    ccache \
    flatpak-builder \
    gh \
    glab \
    iotop-c \
    nicstat \
    numactl \
    ripgrep \
    shfmt \
    sysprof \
    trace-cmd

log "cli-rpms: gh $(rpm -q --qf '%{VERSION}' gh), glab $(rpm -q --qf '%{VERSION}' glab), shellcheck $(rpm -q --qf '%{VERSION}' ShellCheck), shfmt $(rpm -q --qf '%{VERSION}' shfmt)"
