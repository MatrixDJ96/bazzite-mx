#!/usr/bin/env bash
# Sunshine from the vendored COPR: the key, the KMS capabilities, the udev and
# modules-load files, the disabled user unit, and the replacing recipe.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
# shellcheck source=../lib/gpg.sh
source "$CTX/build_files/lib/gpg.sh"

if rpm -q Sunshine > /dev/null && [ -x /usr/bin/sunshine ]; then
    echo "OK: Sunshine $(rpm -q --qf '%{VERSION}' Sunshine)"
else
    echo "FAIL: Sunshine not installed"
fi
caps=$(getcap /usr/bin/sunshine 2>&1 || true)
if [[ $caps == *cap_sys_admin* && $caps == *cap_sys_nice* ]]; then
    echo "OK: /usr/bin/sunshine carries the KMS capabilities ($caps)"
else
    echo "FAIL: /usr/bin/sunshine capabilities: '$caps'"
fi
if sunshine --version 2>&1 | grep -qi sunshine; then
    echo "OK: sunshine --version runs"
else
    echo "FAIL: sunshine --version: $(sunshine --version 2>&1 | head -n1)"
fi

KEY=/etc/pki/rpm-gpg/RPM-GPG-KEY-copr-lizardbyte-stable
FPR=${KEY_FPR[$KEY]}
REPO=/etc/yum.repos.d/sunshine.repo
if [ "$(key_fingerprint "$KEY")" = "$FPR" ]; then
    echo "OK: $KEY fingerprint $FPR"
else
    echo "FAIL: $KEY fingerprint $(key_fingerprint "$KEY" || true)"
fi
if grep -q "^gpgkey=file://$KEY$" "$REPO" && grep -qx 'enabled=0' "$REPO" && ! grep -q '^priority=' "$REPO"; then
    echo "OK: $REPO reads the vendored key, disabled, no priority"
else
    echo "FAIL: $REPO: $(grep -E '^(enabled|gpgkey|priority)=' "$REPO" 2>&1 | tr '\n' ' ')"
fi
if rpm -q gpg-pubkey --qf '%{VERSION}\n' | grep -qi 'e4f68234$'; then
    echo "OK: lizardbyte/stable key in the rpm keyring"
else
    echo "FAIL: lizardbyte/stable key (…e4f68234) not in the rpm keyring"
fi

UNIT=app-dev.lizardbyte.app.Sunshine.service
check_unit_state --global "$UNIT" disabled "opt-in through the recipe"
if grep -q '^Alias=sunshine.service$' "/usr/lib/systemd/user/$UNIT" && grep -q '^ExecStart=/usr/bin/sunshine$' "/usr/lib/systemd/user/$UNIT"; then
    echo "OK: user unit runs /usr/bin/sunshine with the sunshine.service alias"
else
    echo "FAIL: user unit: $(grep -E '^(Alias|ExecStart)=' "/usr/lib/systemd/user/$UNIT" 2>&1 | tr '\n' ' ')"
fi
if grep -q 'KERNEL=="uinput".*GROUP="input"' /usr/lib/udev/rules.d/60-sunshine.rules && grep -qx 'uhid' /usr/lib/modules-load.d/60-sunshine.conf; then
    echo "OK: uinput udev rule and uhid modules-load shipped"
else
    echo "FAIL: 60-sunshine.rules or 60-sunshine.conf missing or changed"
fi
for helper in sunshine-start-vmon sunshine-stop-vmon; do
    if [ -x "/usr/libexec/$helper" ] && bash -n "/usr/libexec/$helper"; then
        echo "OK: base helper /usr/libexec/$helper present"
    else
        echo "FAIL: /usr/libexec/$helper missing or does not parse"
    fi
done
check_desktop_file /usr/share/applications/dev.lizardbyte.app.Sunshine.desktop
if [ -f /usr/share/sunshine/apps.json ] && jq -e '.apps | type == "array"' /usr/share/sunshine/apps.json > /dev/null 2>&1; then
    echo "OK: package apps.json parses"
else
    echo "FAIL: /usr/share/sunshine/apps.json missing or not the expected shape"
fi

NAG=/usr/share/ublue-os/announcements/sunshine-brew.msg.json
if [ ! -e "$NAG" ]; then
    echo "OK: Bazzite's Sunshine Portal announcement removed"
else
    echo "FAIL: $NAG still shipped"
fi

# The recipe that replaces Bazzite's.
RECIPE=/usr/share/ublue-os/just/82-bazzite-sunshine.just
if cmp -s "$CTX/system_files/usr/share/ublue-os/just/82-bazzite-sunshine.just" "$RECIPE"; then
    echo "OK: $RECIPE is the vendored copy"
else
    echo "FAIL: $RECIPE is not the vendored copy"
fi
if [ "$(just --justfile "$RECIPE" --summary 2>&1)" = "setup-sunshine" ]; then
    echo "OK: recipe file defines exactly setup-sunshine"
else
    echo "FAIL: recipe summary: $(just --justfile "$RECIPE" --summary 2>&1)"
fi
tmp=$(mktemp -d)
cp "$RECIPE" "$tmp/justfile"
if just --unstable --fmt --check --justfile "$tmp/justfile" > /dev/null 2>&1; then
    echo "OK: recipe file is just --fmt clean"
else
    echo "FAIL: just --fmt --check: $(just --unstable --fmt --check --justfile "$tmp/justfile" 2>&1 | head -n3)"
fi
rm -rf "$tmp"
if just --justfile "$RECIPE" setup-sunshine help 2>&1 | grep -q '^Usage: ujust setup-sunshine'; then
    echo "OK: setup-sunshine help runs"
else
    echo "FAIL: setup-sunshine help: $(just --justfile "$RECIPE" setup-sunshine help 2>&1 | head -n3)"
fi
if just --justfile /usr/share/ublue-os/justfile --summary 2>&1 | tr ' ' '\n' | grep -qx 'setup-sunshine'; then
    echo "OK: base justfile still imports the recipe"
else
    echo "FAIL: base justfile: $(just --justfile /usr/share/ublue-os/justfile --summary 2>&1 | head -n2)"
fi
