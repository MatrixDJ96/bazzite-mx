#!/usr/bin/bash
# COPR helper functions ported 1:1 from ublue-os/aurora upstream.
# Provides isolated COPR install pattern: enable -> disable -> install
# with explicit --enablerepo=, so the COPR is never globally enabled.

set -euo pipefail

copr_install_isolated() {
    local copr_name="$1"
    shift
    local packages=("$@")

    if [[ ${#packages[@]} -eq 0 ]]; then
        echo "ERROR: No packages specified for copr_install_isolated"
        return 1
    fi

    repo_id="copr:copr.fedorainfracloud.org:${copr_name//\//:}"

    echo "Installing ${packages[*]} from COPR $copr_name (isolated)"

    dnf5 -y copr enable "$copr_name"
    dnf5 -y copr disable "$copr_name"
    dnf5 -y install --enablerepo="$repo_id" "${packages[@]}"

    echo "Installed ${packages[*]} from $copr_name"
}

thirdparty_repo_install() {
    # Install a third-party `*-release`-style RPM that drops a .repo file
    # under /etc/yum.repos.d/, then disable every section in that file so
    # the repo is never globally active. Use --enablerepo=<section> in a
    # follow-up install to pull packages with a runtime-only override.
    #
    # Args:
    #   $1 repo_name        — friendly name, used as default file basename
    #   $2 repo_frompath    — URL/path passed to --repofrompath
    #   $3 release_package  — *-release RPM to install (writes the .repo)
    #   $4 extras_package   — optional extra package to install in same step
    #   $5 repo_file        — optional override for the dropped .repo file
    #                         basename (defaults to "${repo_name}.repo")
    #
    # Why sed and not `dnf5 config-manager setopt`: setopt is a silent
    # no-op on .repo files written by --repofrompath / --from-repofile=URL
    # (verified on dnf5 5.x, Bazzite 44.20260501). Same workaround as in
    # build_files/mx/10-container-runtime.sh — sed is the consistent
    # pattern across every third-party repo touch in this codebase.
    local repo_name="$1"
    local repo_frompath="$2"
    local release_package="$3"
    local extras_package="${4:-}"
    local repo_file="${5:-${repo_name}.repo}"

    echo "Installing $repo_name repo (isolated mode)"

    # shellcheck disable=SC2016
    dnf5 -y install --nogpgcheck --repofrompath "$repo_frompath" "$release_package"

    if [[ -n "$extras_package" ]]; then
        dnf5 -y install "$extras_package" || true
    fi

    local repo_path="/etc/yum.repos.d/${repo_file}"
    if [[ -f "$repo_path" ]]; then
        sed -i 's/^enabled=1/enabled=0/g' "$repo_path"
    else
        echo "WARNING: $repo_path not found after install; isolation may be incomplete"
    fi

    echo "$repo_name repo installed and disabled (ready for isolated usage)"
}
