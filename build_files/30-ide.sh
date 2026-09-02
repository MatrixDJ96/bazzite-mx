#!/usr/bin/env bash
# IDE: Visual Studio Code as the RPM from Microsoft's vendored repository,
# key asserted first. The RPM follows the image, so the skel settings.json
# turns the built-in updater off (code.visualstudio.com/docs/supporting/faq).
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

assert_key_fingerprint /etc/pki/rpm-gpg/RPM-GPG-KEY-microsoft
install_from_repo code code

[ -x /usr/bin/code ] || die "/usr/bin/code missing after install"
[ -f /etc/skel/.config/Code/User/settings.json ] || die "skel settings.json missing"

# The extensions hook is the first consumer of the user unit.
systemctl --global enable ublue-user-setup.service
HOOKS=/usr/share/ublue-os/user-setup.hooks.d
n=$(find "$HOOKS" -maxdepth 1 -name '*.sh' -type f | wc -l)
[ "$n" -gt 0 ] || die "no user-setup hook under $HOOKS"

log "ide: code $(rpm -q --qf '%{VERSION}' code), ublue-user-setup.service enabled for every user, $n user hook(s)"
