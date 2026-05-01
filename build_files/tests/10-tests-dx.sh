#!/usr/bin/bash
# DX smoke tests. Runs after the build orchestrator, immediately before
# bootc container lint. Bloccante: ogni assertion fa exit 1 sulla build.
#
# Phase 1 verifies only the DX overlay markers (sysctl + modules-load).
# Branding (kcm-about Variant=Developer Experience) is best-effort because
# Bazzite's KCM path differs from Aurora and will be wired in a later phase.
# Phase 2-9 will extend this file with rpm-q + systemctl is-enabled
# assertions for each new domain (container, virt, IDE, cockpit, CLI, extras).

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

# --- IP forwarding sysctl marker ---
if [ ! -f /etc/sysctl.d/90-bazzite-mx-dx-forwarding.conf ]; then
    echo "FAIL: missing /etc/sysctl.d/90-bazzite-mx-dx-forwarding.conf"
    exit 1
fi

# --- iptable_nat modules-load marker ---
if [ ! -f /etc/modules-load.d/90-bazzite-mx-dx.conf ]; then
    echo "FAIL: missing /etc/modules-load.d/90-bazzite-mx-dx.conf"
    exit 1
fi

# --- Phase 2: Container runtime packages ---
CONTAINER_RPMS=(
    podman-compose podman-machine podman-tui podman-bootc
    docker-ce docker-ce-cli containerd.io
    docker-buildx-plugin docker-compose-plugin docker-model-plugin
)
for p in "${CONTAINER_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || { echo "FAIL: rpm $p missing"; exit 1; }
done

# --- Phase 2: Container runtime services ---
CONTAINER_UNITS=( docker.socket podman.socket )
for u in "${CONTAINER_UNITS[@]}"; do
    systemctl is-enabled "$u" >/dev/null || { echo "FAIL: $u not enabled"; exit 1; }
done

# --- Phase 3: Virtualization packages ---
VIRT_RPMS=(
    libvirt libvirt-nss
    qemu qemu-img qemu-kvm qemu-system-x86-core
    qemu-char-spice qemu-device-display-virtio-gpu
    qemu-device-display-virtio-vga qemu-device-usb-redirect
    qemu-user-binfmt qemu-user-static
    virt-manager virt-viewer virt-install
    edk2-ovmf
    swtpm swtpm-tools
    waypipe
    guestfs-tools
    ublue-os-libvirt-workarounds
)
for p in "${VIRT_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || { echo "FAIL: rpm $p missing"; exit 1; }
done

# --- Phase 3: Virtualization services ---
# swtpm-workaround.service was historically shipped by an older
# ublue-os-libvirt-workarounds COPR release; it has been consolidated
# into ublue-os-libvirt-workarounds.service in v1.1+ and no longer
# exists as a separate unit.
VIRT_UNITS=(
    ublue-os-libvirt-workarounds.service
    bazzite-mx-groups.service
)
for u in "${VIRT_UNITS[@]}"; do
    systemctl is-enabled "$u" >/dev/null || { echo "FAIL: $u not enabled"; exit 1; }
done

# --- Phase 3: bazzite-mx-groups script must be executable ---
GROUPS_SCRIPT=/usr/libexec/bazzite-mx-groups
if [ ! -x "$GROUPS_SCRIPT" ]; then
    echo "FAIL: $GROUPS_SCRIPT missing or not executable"
    exit 1
fi

echo "DX smoke tests OK."
echo "::endgroup::"
