#!/usr/bin/env bash
# Git tools: GitKraken as an RPM and git-credential-libsecret from Fedora.
# GitKraken has no repository, only a fixed URL that redirects to the current
# release, so the build always gets the latest version.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

GITKRAKEN_URL=https://release.gitkraken.com/linux/gitkraken-amd64.rpm
rpm_file=$BUILD_TMP/gitkraken.rpm

curl -fsSL --retry 3 --retry-delay 5 -o "$rpm_file" "$GITKRAKEN_URL"
rpm -K --nosignature "$rpm_file" > /dev/null || die "gitkraken.rpm: payload digest check failed"
version=$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$rpm_file" 2> /dev/null)
[ -n "$version" ] || die "gitkraken.rpm: not an RPM"
log "gitkraken: downloaded $version ($(stat -c %s "$rpm_file") bytes)"
# The vendor's RPM carries no OpenPGP signature: integrity is TLS to the
# vendor plus the payload digests checked above, hence --no-gpgchecks here.
dnf5 -y --no-gpgchecks install "$rpm_file"
rm -f "$rpm_file"

dnf5 -y install git-credential-libsecret

log "git-tools: gitkraken $(rpm -q --qf '%{VERSION}' gitkraken), git-credential-libsecret $(rpm -q --qf '%{VERSION}' git-credential-libsecret)"
