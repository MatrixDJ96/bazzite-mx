#!/usr/bin/env bash
# IDE: Visual Studio Code as the RPM from Microsoft's vendored repository,
# key asserted first. The RPM follows the image, so the skel settings.json
# turns the built-in updater off (code.visualstudio.com/docs/supporting/faq).
#
# Usage: run by build.sh; no arguments.
# Writes: the code package; ublue-user-setup.service enabled for every user,
#   the extensions hook being its first consumer.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

USER_HOOKS=/usr/share/ublue-os/user-setup.hooks.d

assert_key_fingerprint /etc/pki/rpm-gpg/RPM-GPG-KEY-microsoft
install_from_repo code code

if [ ! -x /usr/bin/code ]; then
    fail_build "/usr/bin/code missing after install"
fi

if [ ! -f /etc/skel/.config/Code/User/settings.json ]; then
    fail_build "skel settings.json missing"
fi

systemctl --global enable ublue-user-setup.service

hook_count=$(find "$USER_HOOKS" -maxdepth 1 -name '*.sh' -type f | wc -l)

if [ "$hook_count" -eq 0 ]; then
    fail_build "no user-setup hook under $USER_HOOKS"
fi

code_version=$(rpm -q --qf '%{VERSION}' code)
log "ide: code $code_version, ublue-user-setup.service enabled for every user," \
    "$hook_count user hook(s)"
