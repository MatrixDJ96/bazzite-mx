#!/usr/bin/env bash
# Installation from repositories that stay disabled in the image: a
# third-party repository ships enabled=0 and is enabled for one dnf5
# transaction only. 90-validate-repos.sh is the gate on that rule.
# Sourced by lib/env.sh.

# <repo-id> is the [section] name of a disabled .repo file, vendored under
# system_files/etc/yum.repos.d/ or shipped by the base.
install_from_repo() {
    local repo=$1
    shift

    dnf5 -y install --enablerepo="$repo" "$@"
}

# The repository ids dnf5 reports enabled, sorted. dnf5's own answer counts
# the override files under /etc/dnf/repos.override.d/, which a comparison of
# the .repo files misses. <root> is a fixture tree for a self-test.
enabled_repos() {
    local root=${1:-/}

    dnf5 -q --installroot="$root" repolist --enabled --json | jq -r '.[].id' | LC_ALL=C sort
}
