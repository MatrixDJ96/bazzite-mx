#!/usr/bin/bash
# COPR helper functions: isolated COPR install pattern
# (enable -> disable -> install with explicit --enablerepo=, so the
# COPR is never globally enabled).

set -euo pipefail

# shellcheck disable=SC1091
source /ctx/build_files/shared/writeback-helpers.sh

copr_install_isolated() {
    local copr_name="$1"
    shift
    local packages=("$@")

    if [[ ${#packages[@]} -eq 0 ]]; then
        echo "ERROR: No packages specified for copr_install_isolated"
        return 1
    fi

    local repo_id="copr:copr.fedorainfracloud.org:${copr_name//\//:}"

    echo "Installing ${packages[*]} from COPR $copr_name (isolated)"

    dnf5 -y copr enable "$copr_name"
    dnf5 -y copr disable "$copr_name"
    dnf5 -y install --enablerepo="$repo_id" "${packages[@]}"

    # `copr enable` writes a new repo file, `copr disable` then flips enabled=
    # IN PLACE. For a COPR the base image already ships (ublue-os/packages) that
    # lands on a base-image path, whose enabled= value validate-repos.sh enforces
    # and a deployed host parses: rewrite it onto a fresh inode (gotcha #34).
    local repo_file="/etc/yum.repos.d/_${repo_id}.repo"
    if [ -f "$repo_file" ]; then
        rewrite_fresh_inode "$repo_file"
    fi

    echo "Installed ${packages[*]} from $copr_name"
}
