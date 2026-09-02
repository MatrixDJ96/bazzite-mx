#!/usr/bin/env bash
# Hook framework: ublue-setup-services runs every script under
# /usr/share/ublue-os/system-setup.hooks.d/ as root at boot and, once its
# user unit is enabled --global, user-setup.hooks.d/ in each session.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

copr_install_isolated ublue-os/packages ublue-setup-services

[ -x /usr/libexec/ublue-system-setup ] || die "ublue-system-setup missing after install"
[ -f /usr/lib/ublue/setup-services/libsetup.sh ] || die "libsetup.sh missing after install"
systemctl enable ublue-system-setup.service

HOOKS=/usr/share/ublue-os/system-setup.hooks.d
n=$(find "$HOOKS" -maxdepth 1 -name '*.sh' -type f | wc -l)
[ "$n" -gt 0 ] || die "no system-setup hook under $HOOKS"
log "setup-services: ublue-system-setup.service enabled, $n system hook(s)"
