#!/usr/bin/bash
# MX smoke tests. Runs after the build orchestrator, immediately before
# bootc container lint. Blocking: every assertion exits 1 on failure.
#
# Each domain script in build_files/mx/ extends this file with rpm-q +
# systemctl is-enabled + file-existence assertions for the things it
# adds, so the test grows in parallel with the build.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

# --- IP forwarding sysctl marker ---
if [ ! -f /etc/sysctl.d/90-bazzite-mx-forwarding.conf ]; then
    echo "FAIL: missing /etc/sysctl.d/90-bazzite-mx-forwarding.conf"
    exit 1
fi

# --- iptable_nat modules-load marker ---
if [ ! -f /etc/modules-load.d/90-bazzite-mx.conf ]; then
    echo "FAIL: missing /etc/modules-load.d/90-bazzite-mx.conf"
    exit 1
fi

# --- Image identity + KDE about-page branding (00-image-info.sh) ---
grep -qE '"image-name":[[:space:]]*"bazzite-mx(-nvidia(-open)?)?"' /usr/share/ublue-os/image-info.json || {
    echo "FAIL: /usr/share/ublue-os/image-info.json image-name not rewritten"
    cat /usr/share/ublue-os/image-info.json
    exit 1
}
grep -qE '"image-vendor":[[:space:]]*"matrixdj96"' /usr/share/ublue-os/image-info.json || {
    echo "FAIL: /usr/share/ublue-os/image-info.json image-vendor not rewritten to matrixdj96"
    grep image-vendor /usr/share/ublue-os/image-info.json || true
    exit 1
}
grep -qE '^VARIANT_ID=bazzite-mx(-nvidia(-open)?)?$' /usr/lib/os-release || {
    echo "FAIL: /usr/lib/os-release VARIANT_ID not rewritten"
    grep ^VARIANT_ID= /usr/lib/os-release || true
    exit 1
}
grep -qE '^Variant=Bazzite-MX( \(NVIDIA( Open)?\))?$' /etc/xdg/kcm-about-distrorc || {
    echo "FAIL: /etc/xdg/kcm-about-distrorc Variant not rewritten or malformed"
    grep ^Variant= /etc/xdg/kcm-about-distrorc || true
    exit 1
}
grep -q '^Website=https://github.com/MatrixDJ96/bazzite-mx$' /etc/xdg/kcm-about-distrorc || {
    echo "FAIL: /etc/xdg/kcm-about-distrorc Website not rewritten"
    grep ^Website= /etc/xdg/kcm-about-distrorc || true
    exit 1
}

# --- Phase 3: Container runtime packages ---
CONTAINER_RPMS=(
    podman-compose podman-machine podman-tui podman-bootc
    docker-ce docker-ce-cli containerd.io
    docker-buildx-plugin docker-compose-plugin docker-model-plugin
)
for p in "${CONTAINER_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || { echo "FAIL: rpm $p missing"; exit 1; }
done

# --- Phase 3: Container runtime services ---
# `is-enabled` returns exit 0 also for static/linked/indirect/alias states,
# which are not what we want. Compare the literal string instead.
CONTAINER_UNITS=( docker.socket podman.socket )
for u in "${CONTAINER_UNITS[@]}"; do
    state=$(systemctl is-enabled "$u" 2>/dev/null || echo missing)
    if [ "$state" != "enabled" ]; then
        echo "FAIL: $u not enabled (state=$state)"
        exit 1
    fi
done

# --- Phase 4: Virtualization packages ---
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

# --- Phase 4: Virtualization services ---
VIRT_UNITS=(
    ublue-os-libvirt-workarounds.service
    libvirtd.service
)
for u in "${VIRT_UNITS[@]}"; do
    state=$(systemctl is-enabled "$u" 2>/dev/null || echo missing)
    if [ "$state" != "enabled" ]; then
        echo "FAIL: $u not enabled (state=$state)"
        exit 1
    fi
done

# --- Phase 4: KVM kargs (kvm.ignore_msrs / kvm.report_ignored_msrs) ---
VIRT_KARGS_FILE=/usr/lib/bootc/kargs.d/01-bazzite-mx-virt.toml
if [ ! -f "$VIRT_KARGS_FILE" ]; then
    echo "FAIL: $VIRT_KARGS_FILE missing"
    exit 1
fi
for k in 'kvm.ignore_msrs=1' 'kvm.report_ignored_msrs=0'; do
    grep -qF "$k" "$VIRT_KARGS_FILE" || {
        echo "FAIL: $VIRT_KARGS_FILE missing karg '$k'"
        exit 1
    }
done

# --- Phase 4: setup-virtualization recipe override ---
VIRT_JUSTFILE=/usr/share/ublue-os/just/84-bazzite-virt.just
if [ ! -f "$VIRT_JUSTFILE" ]; then
    echo "FAIL: $VIRT_JUSTFILE missing"
    exit 1
fi
grep -q 'bazzite-mx OVERRIDE of Bazzite' "$VIRT_JUSTFILE" || {
    echo "FAIL: $VIRT_JUSTFILE is the upstream version (override not applied)"
    exit 1
}
if grep -qE '^[[:space:]]*flatpak install.*org\.virt_manager\.virt-manager' "$VIRT_JUSTFILE"; then
    echo "FAIL: $VIRT_JUSTFILE contains a residual 'flatpak install' line for virt-manager"
    exit 1
fi

# --- Phase 4: virt-manager flatpak blocklist (21-virt-manager-flatpak-exclude.sh) ---
FLATPAK_BLOCKLIST=/usr/share/ublue-os/flatpak-blocklist
grep -q '^deny org\.virt_manager\.virt-manager/\*$' "$FLATPAK_BLOCKLIST" || {
    echo "FAIL: $FLATPAK_BLOCKLIST missing virt-manager deny line"
    exit 1
}

# --- Phase 4: virt-manager flatpak cleanup hooks ---
VIRT_HOOK_SYSTEM=/usr/share/ublue-os/system-setup.hooks.d/16-cleanup-virt-manager-flatpak.sh
VIRT_HOOK_USER=/usr/share/ublue-os/user-setup.hooks.d/16-cleanup-virt-manager-flatpak.sh
if [ ! -x "$VIRT_HOOK_SYSTEM" ]; then
    echo "FAIL: $VIRT_HOOK_SYSTEM missing or not executable"
    exit 1
fi
if [ ! -x "$VIRT_HOOK_USER" ]; then
    echo "FAIL: $VIRT_HOOK_USER missing or not executable"
    exit 1
fi

# --- Phase 5: IDE packages ---
IDE_RPMS=( code )
for p in "${IDE_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || { echo "FAIL: rpm $p missing"; exit 1; }
done

# --- Phase 5: VSCode atomic-aware default settings ---
# Shipped via /etc/skel/.config/Code/User/settings.json so first-login
# user accounts inherit `update.mode=none` (atomic /usr is read-only,
# VSCode self-updater would fail).
VSCODE_SETTINGS=/etc/skel/.config/Code/User/settings.json
if [ ! -f "$VSCODE_SETTINGS" ]; then
    echo "FAIL: $VSCODE_SETTINGS missing"
    exit 1
fi
grep -q '"update.mode": "none"' "$VSCODE_SETTINGS" || {
    echo "FAIL: $VSCODE_SETTINGS missing update.mode=none guard"
    exit 1
}

# --- Phase 5: Git tools (GUI + system helper) ---
GIT_TOOLS_RPMS=( gitkraken git-credential-libsecret )
for p in "${GIT_TOOLS_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || { echo "FAIL: rpm $p missing"; exit 1; }
done

echo "MX smoke tests OK."
