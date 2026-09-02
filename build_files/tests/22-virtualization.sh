#!/usr/bin/env bash
# Virtualization: packages, the modular daemons on and the monolithic one off,
# binfmt out, KVM options, tmpfiles, the group, and the replacing recipe.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..

check_pkg libvirt libvirt-daemon-kvm libvirt-nss qemu-kvm qemu-img virt-manager virt-viewer virt-install \
    edk2-ovmf swtpm swtpm-tools guestfs-tools waypipe quickemu ublue-os-libvirt-workarounds
# tests/40-desktop-apps.sh owns the rest of the blocklist.
check_flatpak_deny 'org.virt_manager.virt-manager/*'
if rpm -q mesa-demos > /dev/null && [ "$(rpm -q --qf '%{VENDOR}' mesa-libGL.x86_64)" = "Terra" ]; then
    echo "OK: mesa-demos $(rpm -q --qf '%{VERSION}' mesa-demos) installed, Mesa still Terra's"
else
    echo "FAIL: mesa-demos $(rpm -q mesa-demos 2>&1 | head -n1); mesa-libGL vendor $(rpm -q --qf '%{VENDOR}' mesa-libGL.x86_64)"
fi
for pkg in qemu-user-binfmt qemu-user-static; do
    if rpm -q "$pkg" > /dev/null 2>&1; then
        echo "FAIL: $pkg installed (the image keeps binfmt out)"
    else
        echo "OK: $pkg absent"
    fi
done

for unit in virtqemud.socket virtqemud.service ublue-os-libvirt-workarounds.service; do
    check_unit_state "$unit" enabled
done
check_unit_state libvirtd.service disabled "modular daemons only"

kver=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n1)
if grep -qx 'options kvm ignore_msrs=1 report_ignored_msrs=0' /usr/lib/modprobe.d/bazzite-mx-kvm.conf \
    && modinfo -k "$kver" -p kvm | grep -q '^ignore_msrs:' \
    && modinfo -k "$kver" -p kvm | grep -q '^report_ignored_msrs:'; then
    echo "OK: kvm options set in modprobe.d and known to kernel $kver"
else
    echo "FAIL: kvm options: $(cat /usr/lib/modprobe.d/bazzite-mx-kvm.conf 2>&1 | grep -v '^#')"
fi
if modinfo -k "$kver" kvmfr > /dev/null 2>&1; then
    echo "OK: kvmfr module present for kernel $kver (base)"
else
    echo "FAIL: kvmfr module missing for kernel $kver"
fi

# Every packaged /var directory is listed, and the file parses.
TMPFILES=/usr/lib/tmpfiles.d/bazzite-mx-virt.conf
missing=0
while read -r dir; do
    grep -q "^d $dir " "$TMPFILES" || {
        echo "FAIL: $dir packaged but not in $TMPFILES"
        missing=1
    }
done < <(rpm -ql libvirt-daemon-common libvirt-daemon-driver-qemu swtpm swtpm-tools \
    | grep -E '^/var/(lib|log|cache)/' | grep -v '^/var/log/libvirt$' | sort -u)
if [ "$missing" -eq 0 ]; then
    echo "OK: every packaged /var directory listed in $TMPFILES"
fi
if systemd-tmpfiles --dry-run --create "$TMPFILES" > /dev/null 2>&1; then
    echo "OK: $TMPFILES parses (dry run)"
else
    echo "FAIL: systemd-tmpfiles rejects $TMPFILES"
fi
if [ -z "$(find /var/lib -mindepth 1 -maxdepth 1 2> /dev/null)" ]; then
    echo "OK: no /var/lib content shipped"
else
    echo "FAIL: /var/lib not empty: $(ls /var/lib)"
fi

if grep -q '^libvirt:' /usr/lib/group && ! grep -q '^libvirt:' /etc/group; then
    echo "OK: libvirt group in /usr/lib/group, not in /etc/group"
else
    echo "FAIL: libvirt group: /usr/lib/group=$(grep '^libvirt:' /usr/lib/group || echo none) /etc/group=$(grep '^libvirt:' /etc/group || echo none)"
fi
if grep -q '^GROUPS_TARGET=(.*libvirt' /usr/share/ublue-os/system-setup.hooks.d/10-bazzite-mx-groups.sh; then
    echo "OK: boot hook grants libvirt"
else
    echo "FAIL: boot hook does not list libvirt"
fi

# The recipe replaces the base's file, parses, is fmt-clean, and help runs.
RECIPE=/usr/share/ublue-os/just/84-bazzite-virt.just
if cmp -s "$RECIPE" "$CTX/system_files$RECIPE"; then
    echo "OK: $RECIPE is ours (base's file replaced)"
else
    echo "FAIL: $RECIPE is not the vendored copy"
fi
if [ "$(just --justfile "$RECIPE" --summary 2>&1)" = "setup-virtualization" ]; then
    echo "OK: recipe file defines exactly setup-virtualization"
else
    echo "FAIL: recipe summary: $(just --justfile "$RECIPE" --summary 2>&1)"
fi
check_just_fmt "$RECIPE"
check_recipe_help "$RECIPE" setup-virtualization
if has_recipe /usr/share/ublue-os/justfile setup-virtualization; then
    echo "OK: base justfile still imports the recipe"
else
    echo "FAIL: base justfile: $(just --justfile /usr/share/ublue-os/justfile --summary 2>&1 | head -n2)"
fi

# tests/01-system-files.sh already compares its content byte for byte.
HELPER=/usr/libexec/bazzite-dx-kvmfr-setup
if [ -x "$HELPER" ] && bash -n "$HELPER"; then
    echo "OK: kvmfr helper executable and parses"
else
    echo "FAIL: $HELPER missing, not executable, or does not parse"
fi
