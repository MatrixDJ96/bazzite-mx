#!/usr/bin/env bash
# Git tools: GitKraken as an RPM and git-credential-libsecret from Fedora.
# GitKraken has no repository, only a fixed URL that redirects to the current
# release, so the build always gets the latest version.
#
# Usage: run by build.sh; no arguments.
# Writes: the gitkraken and git-credential-libsecret packages.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

GITKRAKEN_URL=https://release.gitkraken.com/linux/gitkraken-amd64.rpm
RPM_FILE=$BUILD_TMP/gitkraken.rpm

curl -fsSL --retry 3 --retry-delay 5 -o "$RPM_FILE" "$GITKRAKEN_URL"

if ! rpm -K --nosignature "$RPM_FILE" > /dev/null; then
    fail_build "gitkraken.rpm: payload digest check failed"
fi

version=$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$RPM_FILE" 2> /dev/null)

if [ -z "$version" ]; then
    fail_build "gitkraken.rpm: not an RPM"
fi

log "gitkraken: downloaded $version ($(stat -c %s "$RPM_FILE") bytes)"

# The vendor's RPM carries no OpenPGP signature: integrity is TLS to the
# vendor plus the payload digests checked above, hence --no-gpgchecks here.
dnf5 -y --no-gpgchecks install "$RPM_FILE"
rm -f "$RPM_FILE"

dnf5 -y install git-credential-libsecret

gitkraken_version=$(rpm -q --qf '%{VERSION}' gitkraken)
libsecret_version=$(rpm -q --qf '%{VERSION}' git-credential-libsecret)
log "git-tools: gitkraken $gitkraken_version, git-credential-libsecret $libsecret_version"
