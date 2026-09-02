#!/usr/bin/env bash
# Smoke test of 31-git-tools.sh: GitKraken with its launcher and desktop
# file, and git-credential-libsecret with its helper.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CREDENTIAL_HELPER=/usr/libexec/git-core/git-credential-libsecret

check_gitkraken() {
    if rpm -q gitkraken > /dev/null && [ -x /usr/bin/gitkraken ]; then
        echo "OK: gitkraken $(rpm -q --qf '%{VERSION}' gitkraken), unsigned"
    else
        echo "FAIL: gitkraken not installed or /usr/bin/gitkraken missing"
    fi

    check_desktop_file /usr/share/applications/gitkraken.desktop
}

check_credential_helper() {
    check_pkg git-credential-libsecret

    if [ -x "$CREDENTIAL_HELPER" ]; then
        echo "OK: git-credential-libsecret helper executable"
    else
        echo "FAIL: $CREDENTIAL_HELPER missing"
    fi
}

check_gitkraken
check_credential_helper
