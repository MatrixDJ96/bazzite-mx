#!/usr/bin/env bash
# Virtualization: libvirt as modular daemons, QEMU/KVM, virt-manager and
# quickemu, from an explicit package list with weak dependencies off so the
# binfmt packages stay out.
#
# Usage: run by build.sh; no arguments.
# Writes: the packages; ublue-os-libvirt-workarounds.service enabled; the
#   virt-manager Flatpak denied in the base's Flatpak filter.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

RECIPE=/usr/share/ublue-os/just/84-bazzite-virt.just

# --- helpers ------------------------------------------------------------------

# Prints every installed mesa-* package but mesa-demos, one per line, sorted.
installed_mesa_packages() {
    rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 'mesa-*' \
        | grep -v '^mesa-demos-' \
        | sort -u
}

# Prints `enabled`, `disabled` or the error, whatever the exit status:
# is-enabled exits 1 on a disabled unit, and the caller names the state.
unit_state() {
    systemctl is-enabled "$1" 2>&1 || true
}

# --- the steps ----------------------------------------------------------------

# quickemu needs glxinfo, from mesa-demos. The base excludes `mesa-*` from
# the Fedora repositories because Mesa comes from Terra, and that glob catches
# mesa-demos too: the exclude is lifted for this one package and the build
# proves no other mesa-* package moved.
install_mesa_demos() {
    local before after changed

    before=$(installed_mesa_packages)
    dnf5 -y --setopt=install_weak_deps=False \
        --setopt=fedora.exclude= \
        --setopt=updates.exclude= \
        install mesa-demos
    after=$(installed_mesa_packages)

    if [ "$before" != "$after" ]; then
        changed=$(diff <(echo "$before") <(echo "$after") || true)
        fail_build "installing mesa-demos changed other mesa packages: $changed"
    fi
}

install_virtualization_packages() {
    dnf5 -y --setopt=install_weak_deps=False install \
        edk2-ovmf \
        guestfs-tools \
        libvirt \
        libvirt-daemon-kvm \
        libvirt-nss \
        qemu-char-spice \
        qemu-device-display-virtio-gpu \
        qemu-device-display-virtio-vga \
        qemu-device-usb-redirect \
        qemu-img \
        qemu-kvm \
        quickemu \
        swtpm \
        swtpm-tools \
        virt-install \
        virt-manager \
        virt-viewer \
        waypipe

    copr_install_isolated ublue-os/packages ublue-os-libvirt-workarounds

    # The virt-manager Flatpak would be a twin of the RPM.
    deny_flatpak 'org.virt_manager.virt-manager/*'
}

require_binfmt_out() {
    local package

    for package in qemu-user-binfmt qemu-user-static; do
        if rpm -q "$package" > /dev/null; then
            fail_build "$package was pulled in (the image keeps binfmt out)"
        fi
    done
}

# The Fedora preset enables the modular socket; the monolithic daemon must
# stay off or it takes the sockets over.
require_modular_daemons() {
    local state

    systemctl enable ublue-os-libvirt-workarounds.service

    state=$(unit_state virtqemud.socket)
    if [ "$state" != enabled ]; then
        fail_build "virtqemud.socket is $state (Fedora preset expected to enable it)"
    fi

    state=$(unit_state libvirtd.service)
    if [ "$state" != disabled ]; then
        fail_build "libvirtd.service is $state: the monolithic daemon must stay off"
    fi

    if ! grep -q '^libvirt:' /etc/group; then
        fail_build "libvirt group not created at install"
    fi
}

require_recipe() {
    if [ ! -f "$RECIPE" ]; then
        fail_build "$RECIPE missing"
    fi

    if ! has_recipe "$RECIPE" setup-virtualization; then
        fail_build "$RECIPE does not define setup-virtualization"
    fi
}

# --- main ---------------------------------------------------------------------

install_mesa_demos
install_virtualization_packages
require_binfmt_out
require_modular_daemons
require_recipe

libvirt_version=$(rpm -q --qf '%{VERSION}' libvirt)
qemu_version=$(rpm -q --qf '%{VERSION}' qemu-kvm)
quickemu_version=$(rpm -q --qf '%{VERSION}' quickemu)
log "virtualization: libvirt $libvirt_version, qemu-kvm $qemu_version, quickemu $quickemu_version"
