#!/usr/bin/bash
# MX block 48: fetch the 1Password GPG key on every build.
#
# Why this approach instead of static vendoring at
# `system_files/etc/pki/rpm-gpg/1password.asc`:
#  - bazzite-mx rebuilds hourly via watch-upstream → the key is
#    always fresh, no manual rotation on our side when 1Password
#    rotates the key (the next rebuild catches it).
#  - 1Password doesn't ship an upstream `release` rpm (unlike
#    RPM Fusion in 47-*), so there's no "via dnf install"
#    alternative. Build-time fetch is the natural path.
#  - Trust model: HTTPS endpoint `downloads.1password.com`
#    (official, cited in their Linux docs). TLS verified by the
#    container build CI.
#
# The 1Password `.repo` file stays vendored at
# `system_files/etc/yum.repos.d/1password.repo` because it's our
# policy (enabled=0, repo_gpgcheck=1) and rarely changes — the key
# is the rotating piece, not the config.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

KEY_URL=https://downloads.1password.com/linux/keys/1password.asc
KEY_PATH=/etc/pki/rpm-gpg/1password.asc

curl -fsSL "$KEY_URL" -o "$KEY_PATH"
chmod 0644 "$KEY_PATH"

# Sanity check: valid PGP block + non-empty. If 1Password replaces the
# file with something else (e.g. HTML 404 page or redirect), the build
# fails here instead of at runtime on the user's machine.
[ -s "$KEY_PATH" ] || { echo "FAIL: $KEY_PATH empty"; exit 1; }
grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----$' "$KEY_PATH" || {
    echo "FAIL: $KEY_PATH does not look like a PGP key block"
    exit 1
}

echo "::endgroup::"
