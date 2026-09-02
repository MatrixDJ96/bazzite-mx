#!/usr/bin/env bash
# Hook framework: ublue-setup-services runs every script under
# /usr/share/ublue-os/system-setup.hooks.d/ as root at boot and, once its
# user unit is enabled --global, user-setup.hooks.d/ in each session.
#
# Usage: run by build.sh; no arguments.
# Writes: the ublue-setup-services package; ublue-system-setup.service enabled.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

SYSTEM_HOOKS=/usr/share/ublue-os/system-setup.hooks.d

copr_install_isolated ublue-os/packages ublue-setup-services

if [ ! -x /usr/libexec/ublue-system-setup ]; then
    fail_build "ublue-system-setup missing after install"
fi

if [ ! -f /usr/lib/ublue/setup-services/libsetup.sh ]; then
    fail_build "libsetup.sh missing after install"
fi

systemctl enable ublue-system-setup.service

hook_count=$(find "$SYSTEM_HOOKS" -maxdepth 1 -name '*.sh' -type f | wc -l)

if [ "$hook_count" -eq 0 ]; then
    fail_build "no system-setup hook under $SYSTEM_HOOKS"
fi

log "setup-services: ublue-system-setup.service enabled, $hook_count system hook(s)"
