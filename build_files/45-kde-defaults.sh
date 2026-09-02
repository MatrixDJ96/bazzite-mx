#!/usr/bin/env bash
# KDE defaults: seconds on the panel clock, a panel on every screen, Windows
# style copy and paste in Konsole and PowerShell. They ship as Plasma update
# scripts and skel files, so this script only asserts they landed.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

UPDATES=/usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates
[ -d "$UPDATES" ] || die "$UPDATES missing: plasma-workspace changed its shell package layout"
[ -f "$UPDATES/bazzite-pins.js" ] || die "$UPDATES/bazzite-pins.js missing: Bazzite no longer ships update scripts here"
for js in bazzite-mx-clock-seconds.js bazzite-mx-panels.js; do
    [ -s "$UPDATES/$js" ] || die "$UPDATES/$js missing"
done

SESSIONUI=/etc/skel/.local/share/kxmlgui5/konsole/sessionui.rc
[ -f "$SESSIONUI" ] || die "$SESSIONUI missing"
xmllint --noout "$SESSIONUI" || die "$SESSIONUI is not well-formed XML"
grep -q '<gui name="session" version="1">' "$SESSIONUI" || die "$SESSIONUI: version must stay 1 (merge, not replace)"
rpm -q konsole > /dev/null || die "konsole not in the base"

PROFILE=/etc/skel/.config/powershell/profile.ps1
[ -s "$PROFILE" ] || die "$PROFILE missing"
rpm -q wl-clipboard > /dev/null || die "wl-clipboard not in the base: the PowerShell handlers need wl-copy/wl-paste"

RECIPES=/usr/share/ublue-os/just/95-bazzite-mx.just
[ -f "$RECIPES" ] || die "$RECIPES missing"
has_recipe "$RECIPES" setup-panels || die "$RECIPES does not define setup-panels"

log "kde-defaults: 2 update scripts, Konsole and PowerShell skel files, setup-panels recipe (plasma-workspace $(rpm -q --qf '%{VERSION}' plasma-workspace))"
