#!/usr/bin/env bash
# The staged modules under updates/, stamped for the image's one kernel and
# preferred by modprobe, plus the MControlCenter installer on a fixture. A
# build has no MSI hardware and no system bus, so loading them is a host proof.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
# shellcheck source=../lib/log.sh
source "$CTX/build_files/lib/log.sh"
# shellcheck source=../lib/kmod.sh
source "$CTX/build_files/lib/kmod.sh"
# kernel_version dies, and this test with it, on two kernels or none.
kver=$(kernel_version)
dest=/usr/lib/modules/$kver/updates
echo "OK: one kernel in the image ($kver)"
# The kernel count seen red: an empty tree and a two-kernel tree (subshells,
# because kernel_version dies).
guard=$(mktemp -d)
mkdir -p "$guard/none" "$guard/two/a" "$guard/two/b"
if ! (kernel_version "$guard/none") > /dev/null 2>&1 && ! (kernel_version "$guard/two") > /dev/null 2>&1; then
    echo "OK: kernel_version refuses an empty tree and a two-kernel tree"
else
    echo "FAIL: kernel_version accepted an empty or a two-kernel tree"
fi
rm -rf "$guard"
# A name modprobe refuses resolves to nothing and the test goes on: the
# refusal stays out of the pipeline's status (the form 50-kmods.sh uses).
resolved=$({ modprobe -S "$kver" -n --show-depends bazzite-mx-no-such-module 2>&1 || true; } | awk '$1 == "insmod" { print $2 }' | tail -n1)
if [ -z "$resolved" ]; then
    echo "OK: an unknown module resolves to nothing without ending the test"
else
    echo "FAIL: an unknown module resolved to '$resolved'"
fi

# source.env is the only place a module name or version is written down.
for env in "$CTX"/build_files/kmods/*/source.env; do
    unset KO_NAME KO_VERSION
    # shellcheck disable=SC1090
    source "$env"
    name=$KO_NAME
    ko=$dest/$name.ko
    if [ -f "$ko" ] && modinfo "$ko" > /dev/null 2>&1; then
        echo "OK: $ko is a readable module ($(stat -c %s "$ko") bytes)"
    else
        echo "FAIL: $ko missing or not a module"
        continue
    fi
    vermagic=$(modinfo -F vermagic "$ko")
    if [[ $vermagic == "$kver "* ]]; then
        echo "OK: $name vermagic names $kver"
    else
        echo "FAIL: $name vermagic '$vermagic' does not name $kver"
    fi
    resolved=$({ modprobe -S "$kver" -n --show-depends "$name" 2>&1 || true; } | awk '$1 == "insmod" { print $2 }' | tail -n1)
    if [ -n "$resolved" ] && [ "$(realpath "$resolved")" = "$(realpath "$ko")" ]; then
        echo "OK: modprobe $name resolves to updates/ ($resolved)"
    else
        echo "FAIL: modprobe $name resolves to '$resolved'"
    fi
    if grep -q "^updates/$name.ko:" "/usr/lib/modules/$kver/modules.dep"; then
        echo "OK: updates/$name.ko in modules.dep"
    else
        echo "FAIL: updates/$name.ko not in modules.dep"
    fi
    if modinfo -F sig_id "$ko" 2> /dev/null | grep -q .; then
        echo "FAIL: $name carries a signature"
    else
        echo "OK: $name unsigned"
    fi
    if [ -z "${KO_VERSION:-}" ]; then
        continue
    elif [ "$(modinfo -F version "$ko" 2> /dev/null)" = "$KO_VERSION" ]; then
        echo "OK: $name version $KO_VERSION (source.env's, not the in-tree copy's)"
    else
        echo "FAIL: $name version '$(modinfo -F version "$ko" 2>&1)', source.env says $KO_VERSION"
    fi
done
if [ -f "/usr/lib/modules/$kver/kernel/drivers/platform/x86/msi-ec.ko" ]; then
    echo "OK: the base's in-tree msi-ec is still in place (updates/ wins by depmod order)"
else
    echo "FAIL: the base's in-tree msi-ec.ko is gone"
fi
if [ ! -e /etc/modules-load.d/bazzite-mx-msi.conf ] && ! grep -rqs 'msi-ec\|acpi_ec' /usr/lib/modules-load.d/; then
    echo "OK: nothing loads the modules at boot (opt-in through ujust setup-msi)"
else
    echo "FAIL: a modules-load file names msi-ec or acpi_ec in the image"
fi

# The installer on a fixture root, against a synthetic tarball in the shape
# upstream releases.
HELPER=/usr/libexec/bazzite-mx-msi-setup
if [ -x "$HELPER" ] && bash -n "$HELPER"; then
    echo "OK: $HELPER executable and parses"
else
    echo "FAIL: $HELPER missing, not executable or does not parse"
fi
if [ "$(stat -c %a "$HELPER")" = "755" ]; then
    echo "OK: $HELPER mode 755"
else
    echo "FAIL: $HELPER mode $(stat -c %a "$HELPER")"
fi
work=$(mktemp -d)
top=MControlCenter-9.9-bin
mkdir -p "$work/$top/app"
printf '#!/bin/sh\necho gui\n' > "$work/$top/app/mcontrolcenter"
printf '#!/bin/sh\necho helper\n' > "$work/$top/app/mcontrolcenter-helper"
printf '<busconfig/>\n' > "$work/$top/app/mcontrolcenter-helper.conf"
printf '[D-BUS Service]\nName=mcontrolcenter.helper\nExec=/usr/libexec/mcontrolcenter-helper\nUser=root\n' > "$work/$top/app/mcontrolcenter.helper.service"
printf '[Desktop Entry]\nName=MControlCenter\nExec=mcontrolcenter\nType=Application\n' > "$work/$top/app/mcontrolcenter.desktop"
printf '<svg/>\n' > "$work/$top/app/mcontrolcenter.svg"
tar czf "$work/good.tar.gz" -C "$work" "$top"
fixture=$work/root
if ROOT=$fixture "$HELPER" install "$work/good.tar.gz" > "$work/install.out" 2>&1; then
    echo "OK: installer accepts the release layout ($(tail -n1 "$work/install.out"))"
else
    echo "FAIL: installer refused the good tarball: $(tail -n2 "$work/install.out" | tr '\n' ' ')"
fi
if [ -x "$fixture/usr/local/bin/mcontrolcenter" ] && [ -x "$fixture/usr/local/bin/mcontrolcenter-helper" ] \
    && [ -f "$fixture/usr/local/share/applications/mcontrolcenter.desktop" ] \
    && [ -f "$fixture/usr/local/share/icons/hicolor/scalable/apps/mcontrolcenter.svg" ] \
    && [ -f "$fixture/etc/dbus-1/system.d/mcontrolcenter-helper.conf" ]; then
    echo "OK: GUI and helper in /usr/local/bin, desktop file, icon and D-Bus policy in place"
else
    echo "FAIL: installed layout: $(find "$fixture" -type f | sed "s|$fixture||" | tr '\n' ' ')"
fi
service=$fixture/usr/local/share/dbus-1/system-services/mcontrolcenter.helper.service
if grep -qx 'Exec=/usr/local/bin/mcontrolcenter-helper' "$service" 2> /dev/null && grep -qx 'User=root' "$service" && grep -qx 'Name=mcontrolcenter.helper' "$service"; then
    echo "OK: activation file points at /usr/local/bin/mcontrolcenter-helper, User=root kept"
else
    echo "FAIL: activation file: $(cat "$service" 2>&1 | tr '\n' ' ')"
fi
if [ "$(cat "$fixture/usr/local/share/mcontrolcenter/version" 2> /dev/null)" = "9.9" ]; then
    echo "OK: version recorded from the tarball name (9.9)"
else
    echo "FAIL: version file: '$(cat "$fixture/usr/local/share/mcontrolcenter/version" 2>&1)'"
fi
# Output captured first, against the SIGPIPE in docs/gotchas.md.
status_out=$(ROOT=$fixture "$HELPER" status 2>&1 || true)
if grep -q '^MControlCenter: 9.9 under' <<< "$status_out"; then
    echo "OK: status reports the installed version on the fixture"
else
    echo "FAIL: status: $(grep MControlCenter <<< "$status_out")"
fi
if ROOT=$fixture "$HELPER" remove > /dev/null 2>&1 && [ -z "$(find "$fixture" -type f)" ]; then
    echo "OK: remove takes every installed file back out"
else
    echo "FAIL: after remove: $(find "$fixture" -type f | sed "s|$fixture||" | tr '\n' ' ')"
fi
# Known-bad: both must be refused before anything is installed.
rm -rf "$fixture"
rm -f "$work/$top/app/mcontrolcenter-helper"
tar czf "$work/no-helper.tar.gz" -C "$work" "$top"
if ! ROOT=$fixture "$HELPER" install "$work/no-helper.tar.gz" > /dev/null 2>&1 && [ ! -e "$fixture" ]; then
    echo "OK: installer refuses a tarball without the helper, installs nothing"
else
    echo "FAIL: a tarball without the helper was accepted (or left files)"
fi
mkdir -p "$work/other/app"
tar czf "$work/other.tar.gz" -C "$work" other
if ! ROOT=$fixture "$HELPER" install "$work/other.tar.gz" > /dev/null 2>&1 && [ ! -e "$fixture" ]; then
    echo "OK: installer refuses a tarball with another top directory"
else
    echo "FAIL: a foreign tarball was accepted"
fi
status_out=$("$HELPER" status 2>&1) && status_rc=0 || status_rc=$?
if [ "$status_rc" -eq 0 ] && grep -q '^system vendor: ' <<< "$status_out"; then
    echo "OK: status runs in the build (exit 0, $(wc -l <<< "$status_out") lines)"
else
    echo "FAIL: status exit $status_rc: $(head -n2 <<< "$status_out" | tr '\n' ' ')"
fi
printf 'Acme Computers\n' > "$work/vendor"
if ! DMI_VENDOR_FILE=$work/vendor "$HELPER" enable > "$work/enable.out" 2>&1 && grep -q 'not an MSI system (Acme Computers)' "$work/enable.out"; then
    echo "OK: enable refuses a non-MSI system (DMI gate on a fixture vendor)"
else
    echo "FAIL: enable on a non-MSI build: $(head -n1 "$work/enable.out")"
fi
rm -rf "$work"

RECIPES=/usr/share/ublue-os/just/95-bazzite-mx.just
if has_recipe "$RECIPES" setup-msi; then
    echo "OK: recipe file defines setup-msi"
else
    echo "FAIL: recipe summary: $(just --justfile "$RECIPES" --summary 2>&1)"
fi
help_out=$(just --justfile "$RECIPES" setup-msi help 2>&1 || true)
if grep -q '^Usage: ujust setup-msi' <<< "$help_out"; then
    echo "OK: setup-msi help runs"
else
    echo "FAIL: setup-msi help: $(just --justfile "$RECIPES" setup-msi help 2>&1 | head -n3)"
fi
