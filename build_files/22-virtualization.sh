#!/usr/bin/env bash
# Virtualization: libvirt as modular daemons, QEMU/KVM, virt-manager and
# quickemu, from an explicit package list with weak dependencies off so the
# binfmt packages stay out.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

# quickemu needs glxinfo, from mesa-demos. The base excludes `mesa-*` from
# the Fedora repositories because Mesa comes from Terra, and that glob catches
# mesa-demos too: the exclude is lifted for this one package and the build
# proves no other mesa-* package moved.
mesa_set() {
    rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 'mesa-*' | grep -v '^mesa-demos-' | sort -u
}
before=$(mesa_set)
dnf5 -y --setopt=install_weak_deps=False --setopt=fedora.exclude= --setopt=updates.exclude= install mesa-demos
after=$(mesa_set)
[ "$before" = "$after" ] || die "installing mesa-demos changed other mesa packages: $(diff <(echo "$before") <(echo "$after") || true)"

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

for pkg in qemu-user-binfmt qemu-user-static; do
    ! rpm -q "$pkg" > /dev/null || die "$pkg was pulled in (the image keeps binfmt out)"
done

systemctl enable ublue-os-libvirt-workarounds.service
# is-enabled exits 1 on "disabled": || true keeps the assignment alive under
# set -e so the die below can name the state.
state=$(systemctl is-enabled virtqemud.socket 2>&1 || true)
[ "$state" = enabled ] || die "virtqemud.socket is $state (Fedora preset expected to enable it)"
state=$(systemctl is-enabled libvirtd.service 2>&1 || true)
[ "$state" = disabled ] || die "libvirtd.service is $state: the monolithic daemon must stay off"
grep -q '^libvirt:' /etc/group || die "libvirt group not created at install"

RECIPE=/usr/share/ublue-os/just/84-bazzite-virt.just
[ -f "$RECIPE" ] || die "$RECIPE missing"
has_recipe "$RECIPE" setup-virtualization || die "$RECIPE does not define setup-virtualization"

log "virtualization: libvirt $(rpm -q --qf '%{VERSION}' libvirt), qemu-kvm $(rpm -q --qf '%{VERSION}' qemu-kvm), quickemu $(rpm -q --qf '%{VERSION}' quickemu)"
