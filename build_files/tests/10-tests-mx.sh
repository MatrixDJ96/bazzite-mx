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

# --- Phase 6: Dev/sysadmin CLI tools ---
DEV_CLI_RPMS=(
    android-tools
    bcc bcc-tools bpftrace bpftop
    sysprof iotop-c nicstat numactl trace-cmd
    flatpak-builder
    gh
    cosign
)
for p in "${DEV_CLI_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || { echo "FAIL: rpm $p missing"; exit 1; }
done

# --- Phase 7: Firefox from Mozilla's official RPM repo ---
# The build replaces Bazzite's Flathub flatpak with the Mozilla RPM
# (45-firefox-rpm.sh). Assertions:
#  - firefox + firefox-l10n-it installed
#  - VENDOR = "Mozilla" (guard against regression to the Fedora rpm
#    or accidental layer of the flatpak's bin/firefox)
FIREFOX_RPMS=( firefox firefox-l10n-it )
for p in "${FIREFOX_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || { echo "FAIL: rpm $p missing"; exit 1; }
done
firefox_vendor=$(rpm -q --qf '%{VENDOR}\n' firefox 2>/dev/null)
if [ "$firefox_vendor" != "Mozilla" ]; then
    echo "FAIL: firefox VENDOR is '$firefox_vendor' (expected 'Mozilla')"
    exit 1
fi

# --- Phase 7: Firefox flatpak exclusion ---
INSTALL_LIST=/usr/share/ublue-os/bazzite/flatpak/install
BLOCKLIST=/usr/share/ublue-os/flatpak-blocklist
if [ -f "$INSTALL_LIST" ] && grep -qx "org.mozilla.firefox" "$INSTALL_LIST"; then
    echo "FAIL: $INSTALL_LIST still contains org.mozilla.firefox"
    exit 1
fi
grep -q '^deny org\.mozilla\.firefox/\*$' "$BLOCKLIST" || {
    echo "FAIL: $BLOCKLIST missing firefox deny line"
    exit 1
}

# --- Phase 7: Firefox cleanup hooks (system + user) ---
FIREFOX_HOOK_SYS=/usr/share/ublue-os/system-setup.hooks.d/15-cleanup-firefox-flatpak.sh
FIREFOX_HOOK_USER=/usr/share/ublue-os/user-setup.hooks.d/15-cleanup-firefox-flatpak.sh
if [ ! -x "$FIREFOX_HOOK_SYS" ]; then
    echo "FAIL: $FIREFOX_HOOK_SYS missing or not executable"
    exit 1
fi
if [ ! -x "$FIREFOX_HOOK_USER" ]; then
    echo "FAIL: $FIREFOX_HOOK_USER missing or not executable"
    exit 1
fi

# --- Phase 8: RPM Fusion non-free release pkg + repo files ---
rpm -q rpmfusion-nonfree-release >/dev/null || {
    echo "FAIL: rpmfusion-nonfree-release pkg missing"
    exit 1
}
RPMFUSION_REPOS=(
    /etc/yum.repos.d/rpmfusion-nonfree.repo
    /etc/yum.repos.d/rpmfusion-nonfree-updates.repo
    /etc/yum.repos.d/rpmfusion-nonfree-updates-testing.repo
)
for r in "${RPMFUSION_REPOS[@]}"; do
    [ -f "$r" ] || { echo "FAIL: $r missing"; exit 1; }
    if grep -q "^enabled=1" "$r"; then
        echo "FAIL: $r should be enabled=0 after 47-rpmfusion-release.sh sed"
        exit 1
    fi
done
RPMFUSION_GPGKEY=/etc/pki/rpm-gpg/RPM-GPG-KEY-rpmfusion-nonfree-fedora-44
if [ ! -s "$RPMFUSION_GPGKEY" ]; then
    echo "FAIL: $RPMFUSION_GPGKEY missing or empty"
    exit 1
fi

# --- Phase 8: 1Password vendored repo + GPG key fetched at build ---
ONEPW_REPO=/etc/yum.repos.d/1password.repo
ONEPW_GPGKEY=/etc/pki/rpm-gpg/1password.asc
if [ ! -f "$ONEPW_REPO" ]; then
    echo "FAIL: $ONEPW_REPO missing"
    exit 1
fi
if grep -q "^enabled=1" "$ONEPW_REPO"; then
    echo "FAIL: $ONEPW_REPO should be enabled=0 (runtime-enabled by ujust install-1password)"
    exit 1
fi
if [ ! -s "$ONEPW_GPGKEY" ]; then
    echo "FAIL: $ONEPW_GPGKEY missing or empty (48-1password-key.sh broken?)"
    exit 1
fi

# --- Phase 9: Bazzite-DX gems (ccache + ublue-setup-services COPR) ---
EXTRAS_RPMS=( ccache ublue-setup-services )
for p in "${EXTRAS_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || { echo "FAIL: rpm $p missing"; exit 1; }
done

# --- Phase 9: ublue setup-services framework wiring ---
EXTRAS_UNITS=( ublue-system-setup.service )
for u in "${EXTRAS_UNITS[@]}"; do
    state=$(systemctl is-enabled "$u" 2>/dev/null || echo missing)
    if [ "$state" != "enabled" ]; then
        echo "FAIL: $u not enabled (state=$state)"
        exit 1
    fi
done
if [ ! -f /usr/lib/systemd/user/ublue-user-setup.service ]; then
    echo "FAIL: ublue-user-setup.service unit file missing"
    exit 1
fi

# --- Phase 9: bazzite-mx-groups system-setup hook (v2) ---
GROUPS_HOOK=/usr/share/ublue-os/system-setup.hooks.d/10-bazzite-mx-groups.sh
if [ ! -x "$GROUPS_HOOK" ]; then
    echo "FAIL: $GROUPS_HOOK missing or not executable"
    exit 1
fi
if [ ! -f /usr/lib/ublue/setup-services/libsetup.sh ]; then
    echo "FAIL: /usr/lib/ublue/setup-services/libsetup.sh missing"
    exit 1
fi
grep -qE '^version-script bazzite-mx-groups system 2[[:space:]]' "$GROUPS_HOOK" || {
    echo "FAIL: $GROUPS_HOOK is not at version 2 (regression on docker-group fix)"
    exit 1
}

# --- Phase 9: docker group via sysusers.d (compensates rpm-ostree scriptlet suppression) ---
DOCKER_SYSUSERS=/usr/lib/sysusers.d/bazzite-mx-docker.conf
if [ ! -f "$DOCKER_SYSUSERS" ]; then
    echo "FAIL: $DOCKER_SYSUSERS missing (docker-ce group gap not patched)"
    exit 1
fi
grep -qE '^g[[:space:]]+docker[[:space:]]+-' "$DOCKER_SYSUSERS" || {
    echo "FAIL: $DOCKER_SYSUSERS does not declare 'g docker -' (malformed sysusers)"
    exit 1
}

# --- Phase 10: 95-bazzite-mx.just shipped + master justfile import wired ---
MX_JUSTFILE=/usr/share/ublue-os/just/95-bazzite-mx.just
if [ ! -f "$MX_JUSTFILE" ]; then
    echo "FAIL: $MX_JUSTFILE missing"
    exit 1
fi
grep -q '^install-discord:' "$MX_JUSTFILE" || {
    echo "FAIL: install-discord recipe not found in $MX_JUSTFILE"
    exit 1
}
grep -q '^install-1password:' "$MX_JUSTFILE" || {
    echo "FAIL: install-1password recipe not found in $MX_JUSTFILE"
    exit 1
}
grep -q '^_pkg_layered ' "$MX_JUSTFILE" || {
    echo "FAIL: _pkg_layered private helper not found in $MX_JUSTFILE"
    exit 1
}
grep -q "import \"/usr/share/ublue-os/just/95-bazzite-mx.just\"" /usr/share/ublue-os/justfile || {
    echo "FAIL: import line for 95-bazzite-mx.just missing from master justfile"
    exit 1
}

echo "MX smoke tests OK."
