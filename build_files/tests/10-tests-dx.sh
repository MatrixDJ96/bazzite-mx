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
)
for u in "${VIRT_UNITS[@]}"; do
    state=$(systemctl is-enabled "$u" 2>/dev/null || echo missing)
    if [ "$state" != "enabled" ]; then
        echo "FAIL: $u not enabled (state=$state)"
        exit 1
    fi
done

# --- Phase 4: IDE packages ---
IDE_RPMS=( code )
for p in "${IDE_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || { echo "FAIL: rpm $p missing"; exit 1; }
done

# --- Phase 4: VSCode atomic-aware default settings ---
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

# --- Phase 4: Git tools (GUI + system helper) ---
GIT_TOOLS_RPMS=( gitkraken git-credential-libsecret )
for p in "${GIT_TOOLS_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || { echo "FAIL: rpm $p missing"; exit 1; }
done

# --- Phase 6: Dev/sysadmin CLI tools ---
# 10 Fedora packages + gh from vendored upstream repo. cosign is
# expected to be in Bazzite base (3.0.6+); we assert it for
# defensive depth so a future upstream removal would surface here.
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

# --- Phase 7: Bazzite-DX gems (curated subset) ---
EXTRAS_RPMS=( ccache ublue-setup-services )
for p in "${EXTRAS_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || { echo "FAIL: rpm $p missing"; exit 1; }
done

# --- Phase 7: ublue setup-services framework wiring ---
# system-setup runs at boot (root); user-setup runs at first login (user).
EXTRAS_UNITS=( ublue-system-setup.service )
for u in "${EXTRAS_UNITS[@]}"; do
    state=$(systemctl is-enabled "$u" 2>/dev/null || echo missing)
    if [ "$state" != "enabled" ]; then
        echo "FAIL: $u not enabled (state=$state)"
        exit 1
    fi
done

# user service is enabled --global; in container check, is-enabled
# may return "static" depending on user-preset, so we just assert the
# unit file exists in /usr/lib/systemd/user/.
if [ ! -f /usr/lib/systemd/user/ublue-user-setup.service ]; then
    echo "FAIL: ublue-user-setup.service unit file missing"
    exit 1
fi

# bazzite-mx-groups system-setup hook (replaces the old custom service)
GROUPS_HOOK=/usr/share/ublue-os/system-setup.hooks.d/10-bazzite-mx-groups.sh
if [ ! -x "$GROUPS_HOOK" ]; then
    echo "FAIL: $GROUPS_HOOK missing or not executable"
    exit 1
fi

# libsetup.sh must be present (the hook sources it).
if [ ! -f /usr/lib/ublue/setup-services/libsetup.sh ]; then
    echo "FAIL: /usr/lib/ublue/setup-services/libsetup.sh missing"
    exit 1
fi

# --- Phase 8: Firefox da repo RPM ufficiale Mozilla ---
# La build sostituisce il flatpak Flathub di Bazzite con il rpm Mozilla
# (45-firefox-rpm.sh). Asserzioni:
#  - firefox + firefox-l10n-it installati
#  - VENDOR = "Mozilla" (guardia contro regressione al rpm Fedora se in
#    futuro venisse aggiunto al base Bazzite)
FIREFOX_RPMS=( firefox firefox-l10n-it )
for p in "${FIREFOX_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || { echo "FAIL: rpm $p missing"; exit 1; }
done

# La VENDOR field "Mozilla" è la stringa esatta dal pacchetto Mozilla
# RPM (verificata 2026-05-02 su firefox-150.0.1-1; il pacchetto Fedora
# userebbe "Fedora Project"). head -1 difensivo per il caso (improbabile
# in build pulita) di NEVR multipli installati post-failed-reinstall.
FIREFOX_VENDOR=$(rpm -q firefox --qf '%{VENDOR}\n' | head -1)
if [ "$FIREFOX_VENDOR" != "Mozilla" ]; then
    echo "FAIL: firefox vendor is '$FIREFOX_VENDOR', expected 'Mozilla'"
    exit 1
fi

# --- Phase 8: esclusione flatpak Firefox ---
# 46-firefox-flatpak-exclude.sh patcha la default-install list di
# Bazzite e estende il blocklist Flathub. Verifichiamo che entrambi
# gli interventi siano effettivi.
FIREFOX_INSTALL_LIST=/usr/share/ublue-os/bazzite/flatpak/install
if grep -q '^org\.mozilla\.firefox$' "$FIREFOX_INSTALL_LIST"; then
    echo "FAIL: org.mozilla.firefox ancora presente in $FIREFOX_INSTALL_LIST"
    exit 1
fi

FIREFOX_BLOCKLIST=/usr/share/ublue-os/flatpak-blocklist
if ! grep -q '^deny org\.mozilla\.firefox/\*$' "$FIREFOX_BLOCKLIST"; then
    echo "FAIL: deny org.mozilla.firefox/* non trovato in $FIREFOX_BLOCKLIST"
    exit 1
fi

# --- Phase 8: cleanup hooks (system + user) ---
FIREFOX_HOOK_SYSTEM=/usr/share/ublue-os/system-setup.hooks.d/15-cleanup-firefox-flatpak.sh
FIREFOX_HOOK_USER=/usr/share/ublue-os/user-setup.hooks.d/15-cleanup-firefox-flatpak.sh
if [ ! -x "$FIREFOX_HOOK_SYSTEM" ]; then
    echo "FAIL: $FIREFOX_HOOK_SYSTEM missing or not executable"
    exit 1
fi
if [ ! -x "$FIREFOX_HOOK_USER" ]; then
    echo "FAIL: $FIREFOX_HOOK_USER missing or not executable"
    exit 1
fi

echo "DX smoke tests OK."
echo "::endgroup::"
