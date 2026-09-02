#!/usr/bin/env bash
# GitKraken with its launcher, and git-credential-libsecret's helper.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

if rpm -q gitkraken > /dev/null && [ -x /usr/bin/gitkraken ]; then
    echo "OK: gitkraken $(rpm -q --qf '%{VERSION}' gitkraken), unsigned"
else
    echo "FAIL: gitkraken not installed or /usr/bin/gitkraken missing"
fi
check_desktop_file /usr/share/applications/gitkraken.desktop

check_pkg git-credential-libsecret
[ -x /usr/libexec/git-core/git-credential-libsecret ] && echo "OK: git-credential-libsecret helper executable" || echo "FAIL: /usr/libexec/git-core/git-credential-libsecret missing"
