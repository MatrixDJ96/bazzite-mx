#!/usr/bin/env bash
# Installation from repositories that stay disabled in the image: a
# third-party repository ships enabled=0 and is enabled for one dnf5
# transaction only. 90-validate-repos.sh is the gate on that rule.

# install_from_repo <repo-id> <package>...: the repo id is the [section] name
# of a .repo file vendored under system_files/etc/yum.repos.d/.
install_from_repo() {
    local repo=$1
    shift
    [ $# -gt 0 ] || die "install_from_repo $repo: no packages given"
    dnf5 -y install --enablerepo="$repo" "$@"
}

# copr_install_isolated <owner/project> <package>...: enable the COPR so dnf5
# writes its .repo file, disable it again so the file ends up enabled=0, then
# install with the repo enabled for this transaction only.
copr_install_isolated() {
    local copr=$1
    shift
    [ $# -gt 0 ] || die "copr_install_isolated $copr: no packages given"
    local repo_id="copr:copr.fedorainfracloud.org:${copr//\//:}"
    dnf5 -y copr enable "$copr"
    dnf5 -y copr disable "$copr"
    dnf5 -y install --enablerepo="$repo_id" "$@"
}
