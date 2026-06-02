#!/usr/bin/bash
# MX block 20: Virtualization stack.
# Adds libvirt + QEMU full stack, virt-manager/virt-viewer GUIs,
# swtpm (Windows 11 / TPM-aware Linux), waypipe (Wayland-native
# remote display), and the ublue-os-libvirt-workarounds COPR.
#
# Weak deps are kept on (no --setopt=install_weak_deps=False) so
# libvirt's Recommends land automatically without manually tracking
# every helper package across libvirt releases.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

# shellcheck disable=SC1091
source /ctx/build_files/shared/copr-helpers.sh

### Section 1: Virtualization core (libvirt + QEMU + tools) ###
# edk2-ovmf is already in the Bazzite base; listed here so the smoke
# test asserts it.
dnf5 install -y \
    libvirt \
    libvirt-nss \
    qemu \
    qemu-img \
    qemu-kvm \
    qemu-system-x86-core \
    qemu-char-spice \
    qemu-device-display-virtio-gpu \
    qemu-device-display-virtio-vga \
    qemu-device-usb-redirect \
    qemu-user-binfmt \
    qemu-user-static \
    virt-manager \
    virt-viewer \
    virt-install \
    edk2-ovmf \
    swtpm \
    swtpm-tools \
    waypipe \
    guestfs-tools

### Section 2: ublue-os-libvirt-workarounds (COPR isolated) ###
# Ships ublue-os-libvirt-workarounds.service, which runs
# `restorecon -R /var/{log,lib}/libvirt/` to fix SELinux contexts after
# a fresh install on atomic distros (auto-enabled via the package preset).
copr_install_isolated "ublue-os/packages" "ublue-os-libvirt-workarounds"

### Section 3: Services ###
# Explicit enable is defense-in-depth on top of the package preset, so
# the smoke test catches any future preset change.
systemctl enable ublue-os-libvirt-workarounds.service

# libvirtd.service ships DISABLED by libvirt's preset on Bazzite. The
# upstream `ujust setup-virtualization virt-on` recipe that would enable
# it at runtime is gated on `! rpm -q virt-manager`, which is FALSE here
# (virt-manager is RPM-installed in section 1) — so enable it at build
# time to avoid a silently broken stack.
systemctl enable libvirtd.service

echo "::endgroup::"
