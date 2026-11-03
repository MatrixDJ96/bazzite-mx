#!/usr/bin/env bash
# Installation from repositories that stay disabled in the image: a
# third-party repository ships enabled=0 and is enabled for one dnf5
# transaction only. 90-validate-repos.sh is the gate on that rule. Every dnf5
# call that reaches a mirror goes through dnf_retry.
# Sourced by lib/env.sh and kmods/build-kmods.sh; dnf_retry logs with
# lib/log.sh.

# dnf_retry <dnf5 arguments>: dnf5, up to five tries a minute apart, the last
# try's status returned: one mirror or COPR failing one request would otherwise
# fail the flavour's whole build.
dnf_retry() {
    local try

    for try in 1 2 3 4; do
        if dnf5 "$@"; then
            return 0
        fi

        log "dnf5 $* failed (try $try of 5), retrying in 60 s"
        sleep 60
    done

    dnf5 "$@"
}

# <repo-id> is the [section] name of a disabled .repo file, vendored under
# system_files/etc/yum.repos.d/ or shipped by the base.
install_from_repo() {
    local repo=$1
    shift

    dnf_retry -y install --enablerepo="$repo" "$@"
}

# The repository ids dnf5 reports enabled, sorted. dnf5's own answer counts
# the override files under /etc/dnf/repos.override.d/, which a comparison of
# the .repo files misses. <root> is a fixture tree for a self-test.
enabled_repos() {
    local root=${1:-/}

    dnf5 -q --installroot="$root" repolist --enabled --json | jq -r '.[].id' | LC_ALL=C sort
}
