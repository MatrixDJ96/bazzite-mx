#!/usr/bin/env bash
# mise, the per-user runtime manager, as the RPM from the COPR its own
# documentation names (mise.jdx.dev/installing-mise), key asserted first, so
# every host has the same binary. The runtimes stay a per-user `mise install`.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

assert_key_fingerprint /etc/pki/rpm-gpg/RPM-GPG-KEY-copr-jdxcode-mise
install_from_repo copr:copr.fedorainfracloud.org:jdxcode:mise mise

[ -x /usr/bin/mise ] || die "/usr/bin/mise missing after install"
[ -f /etc/profile.d/mise.sh ] || die "/etc/profile.d/mise.sh missing"
[ -f /etc/skel/.config/mise/config.toml ] || die "skel mise config.toml missing"

log "mise: $(rpm -q --qf '%{VERSION}' mise)"
