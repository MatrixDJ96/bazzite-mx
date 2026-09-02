#!/usr/bin/env bash
# Smoke test of 22-virtualization.sh: the packages, the modular libvirt
# daemons on and the monolithic one off, binfmt kept out, the KVM options,
# the tmpfiles list, the libvirt group and the recipe that replaces the base's.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree);
# by hand: bash build_files/tests/22-virtualization.sh with the repo at ../..
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
KVM_OPTIONS=/usr/lib/modprobe.d/bazzite-mx-kvm.conf
TMPFILES=/usr/lib/tmpfiles.d/bazzite-mx-virt.conf
GROUPS_HOOK=/usr/share/ublue-os/system-setup.hooks.d/10-bazzite-mx-groups.sh
RECIPE=/usr/share/ublue-os/just/84-bazzite-virt.just
KVMFR_HELPER=/usr/libexec/bazzite-dx-kvmfr-setup

check_packages() {
    local package mesa_vendor

    check_pkg libvirt libvirt-daemon-kvm libvirt-nss qemu-kvm qemu-img virt-manager \
        virt-viewer virt-install edk2-ovmf swtpm swtpm-tools guestfs-tools waypipe \
        quickemu ublue-os-libvirt-workarounds

    # tests/40-desktop-apps.sh owns the rest of the blocklist.
    check_flatpak_deny 'org.virt_manager.virt-manager/*'

    # mesa-demos comes from Fedora through a lifted exclude; Mesa itself must
    # still be Terra's.
    mesa_vendor=$(rpm -q --qf '%{VENDOR}' mesa-libGL.x86_64)
    if rpm -q mesa-demos > /dev/null && [ "$mesa_vendor" = "Terra" ]; then
        echo "OK: mesa-demos $(rpm -q --qf '%{VERSION}' mesa-demos) installed, Mesa still Terra's"
    else
        echo "FAIL: mesa-demos $(rpm -q mesa-demos 2>&1 | head -n1); mesa-libGL vendor $mesa_vendor"
    fi

    for package in qemu-user-binfmt qemu-user-static; do
        if rpm -q "$package" > /dev/null 2>&1; then
            echo "FAIL: $package installed (the image keeps binfmt out)"
        else
            echo "OK: $package absent"
        fi
    done
}

check_daemons() {
    local unit

    for unit in virtqemud.socket virtqemud.service ublue-os-libvirt-workarounds.service; do
        check_unit_state "$unit" enabled
    done
    check_unit_state libvirtd.service disabled "modular daemons only"
}

check_kvm_options() {
    local kernel=$1 parameters

    # Both options must exist in the kernel's kvm module, or modprobe would
    # refuse the line at boot.
    parameters=$(modinfo -k "$kernel" -p kvm 2> /dev/null || true)
    if grep -qx 'options kvm ignore_msrs=1 report_ignored_msrs=0' "$KVM_OPTIONS" \
        && grep -q '^ignore_msrs:' <<< "$parameters" \
        && grep -q '^report_ignored_msrs:' <<< "$parameters"; then
        echo "OK: kvm options set in modprobe.d and known to kernel $kernel"
    else
        echo "FAIL: kvm options: $(cat "$KVM_OPTIONS" 2>&1 | grep -v '^#')"
    fi

    if modinfo -k "$kernel" kvmfr > /dev/null 2>&1; then
        echo "OK: kvmfr module present for kernel $kernel (base)"
    else
        echo "FAIL: kvmfr module missing for kernel $kernel"
    fi
}

# /var/log/libvirt is the base's own line.
packaged_var_directories() {
    rpm -ql libvirt-daemon-common libvirt-daemon-driver-qemu swtpm swtpm-tools \
        | grep -E '^/var/(lib|log|cache)/' \
        | grep -v '^/var/log/libvirt$' \
        | sort -u
}

check_tmpfiles() {
    local directory missing=0

    while read -r directory; do
        if ! grep -q "^d $directory " "$TMPFILES"; then
            echo "FAIL: $directory packaged but not in $TMPFILES"
            missing=1
        fi
    done < <(packaged_var_directories)
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
}

check_libvirt_group() {
    local in_usr in_etc

    # 95-clean-stage.sh moves the group where NSS reads it, so a host's /etc
    # merge cannot drop it.
    if grep -q '^libvirt:' /usr/lib/group && ! grep -q '^libvirt:' /etc/group; then
        echo "OK: libvirt group in /usr/lib/group, not in /etc/group"
    else
        in_usr=$(grep '^libvirt:' /usr/lib/group || echo none)
        in_etc=$(grep '^libvirt:' /etc/group || echo none)
        echo "FAIL: libvirt group: /usr/lib/group=$in_usr /etc/group=$in_etc"
    fi

    if grep -q '^GROUPS_TARGET=(.*libvirt' "$GROUPS_HOOK"; then
        echo "OK: boot hook grants libvirt"
    else
        echo "FAIL: boot hook does not list libvirt"
    fi
}

check_recipe() {
    local summary

    if cmp -s "$RECIPE" "$CTX/system_files$RECIPE"; then
        echo "OK: $RECIPE is ours (base's file replaced)"
    else
        echo "FAIL: $RECIPE is not the vendored copy"
    fi

    summary=$(just --justfile "$RECIPE" --summary 2>&1 || true)
    if [ "$summary" = "setup-virtualization" ]; then
        echo "OK: recipe file defines exactly setup-virtualization"
    else
        echo "FAIL: recipe summary: $summary"
    fi

    check_just_fmt "$RECIPE"
    check_recipe_help "$RECIPE" setup-virtualization

    if has_recipe /usr/share/ublue-os/justfile setup-virtualization; then
        echo "OK: base justfile still imports the recipe"
    else
        summary=$(just --justfile /usr/share/ublue-os/justfile --summary 2>&1 | head -n2)
        echo "FAIL: base justfile: $summary"
    fi
}

names_assigned_by() {
    local script=$1

    grep -vE '^[[:space:]]*#' "$script" \
        | grep -oE '(^|[[:space:]])[A-Za-z_][A-Za-z0-9_]*=' \
        | tr -d ' =' \
        | sort -u
}

# The helper sources ujust.sh, whose libraries declare their colour and
# formatting names readonly; an assignment to one of them fails at every run
# (docs/gotchas.md § `ujust.sh` declares its colour and formatting names
# readonly). The list is read from the image, and an empty list is a failure:
# the probe cannot see, and a pass would prove nothing.
check_kvmfr_helper() {
    local readonly_names assigned clash

    if [ -x "$KVMFR_HELPER" ] && bash -n "$KVMFR_HELPER"; then
        echo "OK: kvmfr helper executable and parses"
    else
        echo "FAIL: $KVMFR_HELPER missing, not executable, or does not parse"
    fi

    readonly_names=$(grep -hoE '^declare -r [A-Za-z_]+' /usr/lib/ujust/*.sh \
        | awk '{ print $3 }' | sort -u)
    assigned=$(names_assigned_by "$KVMFR_HELPER")
    clash=$(grep -xF -f <(echo "$readonly_names") <<< "$assigned" || true)

    if [ -z "$readonly_names" ]; then
        echo "FAIL: no readonly name found under /usr/lib/ujust" \
            "(the ujust libraries changed shape?)"
    elif [ -z "$clash" ]; then
        echo "OK: kvmfr helper assigns none of the $(wc -l <<< "$readonly_names") names" \
            "ujust.sh declares readonly"
    else
        echo "FAIL: kvmfr helper assigns readonly ujust.sh names: $(tr '\n' ' ' <<< "$clash")"
    fi
}

kernel=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n1)

check_packages
check_daemons
check_kvm_options "$kernel"
check_tmpfiles
check_libvirt_group
check_recipe
check_kvmfr_helper
