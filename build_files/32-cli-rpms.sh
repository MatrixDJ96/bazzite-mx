#!/usr/bin/env bash
# Command-line tools from Fedora, none of them in the base. Fedora's shfmt is
# the release CI and the edit hook format with, so the image, the hook and CI
# agree on the formatter (docs/conventions.md).
#
# Usage: run by build.sh; no arguments.
# Writes: the packages listed below.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

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

gh_version=$(rpm -q --qf '%{VERSION}' gh)
glab_version=$(rpm -q --qf '%{VERSION}' glab)
shellcheck_version=$(rpm -q --qf '%{VERSION}' ShellCheck)
shfmt_version=$(rpm -q --qf '%{VERSION}' shfmt)
log "cli-rpms: gh $gh_version, glab $glab_version, shellcheck $shellcheck_version," \
    "shfmt $shfmt_version"
