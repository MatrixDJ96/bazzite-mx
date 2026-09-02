#!/usr/bin/env bash
# mise, the per-user runtime manager, as the RPM from the COPR its own
# documentation names (mise.jdx.dev/installing-mise), key asserted first, so
# every host has the same binary. The runtimes stay a per-user `mise install`.
#
# Usage: run by build.sh; no arguments.
# Writes: the mise package. The shell activation and the skel defaults come
#   from system_files/ and are only checked here.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

assert_key_fingerprint /etc/pki/rpm-gpg/RPM-GPG-KEY-copr-jdxcode-mise
install_from_repo copr:copr.fedorainfracloud.org:jdxcode:mise mise

if [ ! -x /usr/bin/mise ]; then
    fail_build "/usr/bin/mise missing after install"
fi

if [ ! -f /etc/profile.d/mise.sh ]; then
    fail_build "/etc/profile.d/mise.sh missing"
fi

if [ ! -f /etc/skel/.config/mise/config.toml ]; then
    fail_build "skel mise config.toml missing"
fi

log "mise: $(rpm -q --qf '%{VERSION}' mise)"
