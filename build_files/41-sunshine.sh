#!/usr/bin/env bash
# Sunshine, the Moonlight streaming host, as the COPR RPM: KMS capture needs
# file capabilities a Flatpak cannot carry. The user unit stays disabled for
# everyone and `ujust setup-sunshine` enables it per user.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

UNIT=app-dev.lizardbyte.app.Sunshine.service

assert_key_fingerprint /etc/pki/rpm-gpg/RPM-GPG-KEY-copr-lizardbyte-stable
# The COPR names the package "Sunshine", capital S.
install_from_repo copr:copr.fedorainfracloud.org:lizardbyte:stable Sunshine

[ -x /usr/bin/sunshine ] || die "/usr/bin/sunshine missing after install"
caps=$(getcap /usr/bin/sunshine)
[[ $caps == *cap_sys_admin* && $caps == *cap_sys_nice* ]] || die "/usr/bin/sunshine lacks the KMS capabilities: '$caps'"
[ -f "/usr/lib/systemd/user/$UNIT" ] || die "$UNIT missing"
[ -f /usr/lib/udev/rules.d/60-sunshine.rules ] || die "60-sunshine.rules missing"
[ -f /usr/lib/modules-load.d/60-sunshine.conf ] || die "60-sunshine.conf missing"
for helper in sunshine-start-vmon sunshine-stop-vmon; do
    [ -x "/usr/libexec/$helper" ] || die "/usr/libexec/$helper missing: the base no longer ships the virtual-monitor helpers"
done

# Fedora's user presets do not enable it: asserted rather than assumed.
systemctl --global disable "$UNIT"
state=$(systemctl --global is-enabled "$UNIT" 2>&1 || true)
[ "$state" = disabled ] || die "$UNIT is $state for users (expected disabled)"

NAG=/usr/share/ublue-os/announcements/sunshine-brew.msg.json
if [ -f "$NAG" ]; then
    rm -f "$NAG"
    log "sunshine: removed Bazzite's Portal announcement $NAG"
fi

RECIPE=/usr/share/ublue-os/just/82-bazzite-sunshine.just
[ -f "$RECIPE" ] || die "$RECIPE missing"
has_recipe "$RECIPE" setup-sunshine || die "$RECIPE does not define setup-sunshine"

log "sunshine: Sunshine $(rpm -q --qf '%{VERSION}' Sunshine), $caps, $UNIT disabled for users"
