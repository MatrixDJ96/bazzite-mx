#!/usr/bin/bash
# DX block 20: Virtualization stack.
# Adds libvirt + QEMU full stack, virt-manager/virt-viewer GUIs,
# swtpm (Windows 11 / TPM-aware Linux), waypipe (Wayland-native
# remote display), and the ublue-os-libvirt-workarounds COPR which
# ships swtpm-workaround.service + ublue-os-libvirt-workarounds.service.
#
# Why no `--setopt=install_weak_deps=False`: we want libvirt's
# Recommends (libvirt-nss, swtpm-tools-pulled-via-swtpm, ...) to land
# automatically. Bazzite-DX upstream uses weak_deps=False to keep the
# image lean, but that path requires manually tracking every helper
# package across libvirt releases. Aurora's pattern (which we follow
# here) is more maintainable and consistent with our porting plan.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

# shellcheck disable=SC1091
source /ctx/build_files/shared/copr-helpers.sh

### Section 1: Virtualization core (libvirt + QEMU + tools) ###
# edk2-ovmf is already in the Bazzite base; we list it here for
# explicitness and so the smoke test can assert it's present.
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
# Currently ships:
#   - /usr/lib/systemd/system/ublue-os-libvirt-workarounds.service
#       Runs `restorecon -R /var/{log,lib}/libvirt/` to fix SELinux
#       contexts after a fresh install on atomic distros. Auto-enabled
#       via the package's systemd-preset file.
#
# Note: an older release of this COPR shipped a separate
# `swtpm-workaround.service` (still referenced in upstream Aurora's
# build script). It has been consolidated and no longer exists in
# v1.1+. swtpm itself works out of the box once installed; no
# additional service is needed for libvirt + Windows 11 TPM scenarios.
copr_install_isolated "ublue-os/packages" "ublue-os-libvirt-workarounds"

### Section 3: Services ###
# `ublue-os-libvirt-workarounds.service` is auto-enabled by the
# package preset; the explicit enable below is defense-in-depth so
# the smoke test catches any future preset behaviour change.
#
# `bazzite-mx-groups.service` (shipped via system_files) appends
# docker + libvirt groups to /etc/group on first boot and adds wheel
# users to them. Without this, Phase 2's docker.socket and Phase 3's
# libvirt would only be usable via sudo.
systemctl enable ublue-os-libvirt-workarounds.service
systemctl enable bazzite-mx-groups.service

# Note: libvirtd / virtqemud sockets are pre-enabled by the libvirt
# package's systemd-preset, so no explicit enable here.

echo "::endgroup::"
