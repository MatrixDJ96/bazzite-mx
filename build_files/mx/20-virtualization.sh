#!/usr/bin/bash
# MX block 20: Virtualization stack.
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
# Note: docker + libvirt group setup for wheel users used to live in a
# custom `bazzite-mx-groups.service` enabled here. Phase 7 migrated it
# to a system-setup hook (system_files/usr/share/ublue-os/system-setup
# .hooks.d/10-bazzite-mx-groups.sh) under the ublue-setup-services
# framework. The hook now runs from `ublue-system-setup.service` which
# Phase 7 enables.
systemctl enable ublue-os-libvirt-workarounds.service

# `libvirtd.service` is shipped DISABLED by libvirt's preset on Bazzite
# (verified 2026-05-03 against ghcr.io/ublue-os/bazzite:stable: the
# unit is `disabled` even though `virtqemud.socket` is pre-enabled).
# Upstream's `ujust setup-virtualization virt-on` recipe would enable
# it at runtime, but that recipe is gated on `! rpm -q virt-manager`,
# which is FALSE on our image (we ship virt-manager as RPM in section
# 1) — so the user gets a silently broken stack. Enable it here at
# build time, matching AmyOS's pattern (`install-apps.sh:104`).
systemctl enable libvirtd.service

echo "::endgroup::"
