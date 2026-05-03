#!/usr/bin/bash
# MX smoke tests. Runs after the build orchestrator, immediately before
# bootc container lint. Bloccante: ogni assertion fa exit 1 sulla build.
#
# Phase 1 verifies the MX build markers (sysctl + modules-load) and
# branding (image-info.json image-name, os-release VARIANT_ID,
# kcm-about-distrorc Variant). Phase 2-9 extend this file with rpm-q +
# systemctl is-enabled assertions for each new domain (container, virt,
# IDE, CLI, extras, firefox, ujust install-* recipes).

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
# image-info.json image-name deve riflettere il fork.
grep -qE '"image-name":[[:space:]]*"bazzite-mx(-nvidia(-open)?)?"' /usr/share/ublue-os/image-info.json || {
    echo "FAIL: /usr/share/ublue-os/image-info.json image-name not rewritten"
    cat /usr/share/ublue-os/image-info.json
    exit 1
}
# os-release VARIANT_ID idem.
grep -qE '^VARIANT_ID=bazzite-mx(-nvidia(-open)?)?$' /usr/lib/os-release || {
    echo "FAIL: /usr/lib/os-release VARIANT_ID not rewritten"
    grep ^VARIANT_ID= /usr/lib/os-release || true
    exit 1
}
# KDE about page (Variant + Website).
# Regex anchored on both ends: matcha solo le 3 stringhe valide
# ('Bazzite-MX', 'Bazzite-MX (NVIDIA)', 'Bazzite-MX (NVIDIA Open)') e
# rifiuta valori malformati tipo 'Bazzite-MX-BROKEN' o 'Bazzite-MXfoo'.
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

# --- Phase 8: Discord ujust + RPM Fusion non-free (rpmfusion-nonfree-release pkg) ---
# Discord NON è installato di default (è una ricetta opt-in via ujust).
# I .repo + GPG keys arrivano dal pacchetto rpmfusion-nonfree-release
# (47-rpmfusion-release.sh) — niente vendoring statico, future-proof.
rpm -q rpmfusion-nonfree-release >/dev/null || {
    echo "FAIL: rpmfusion-nonfree-release pkg missing (47-rpmfusion-release.sh broken?)"
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

# La GPG key arriva dal pacchetto rpmfusion-nonfree-release (insieme a
# le key per Fedora 45/46/rawhide). Verifichiamo che almeno la key
# corrente per F44 sia al posto: senza di essa, il primo
# `rpm-ostree install discord` via ujust prompt l'utente.
RPMFUSION_GPGKEY=/etc/pki/rpm-gpg/RPM-GPG-KEY-rpmfusion-nonfree-fedora-44
if [ ! -s "$RPMFUSION_GPGKEY" ]; then
    echo "FAIL: $RPMFUSION_GPGKEY missing or empty"
    exit 1
fi
grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----$' "$RPMFUSION_GPGKEY" || {
    echo "FAIL: $RPMFUSION_GPGKEY non sembra un PGP key block"
    exit 1
}

# 95-bazzite-mx.just deve esistere con la ricetta install-discord.
MX_JUSTFILE=/usr/share/ublue-os/just/95-bazzite-mx.just
if [ ! -f "$MX_JUSTFILE" ]; then
    echo "FAIL: $MX_JUSTFILE missing"
    exit 1
fi
grep -q '^install-discord:' "$MX_JUSTFILE" || {
    echo "FAIL: install-discord recipe not found in $MX_JUSTFILE"
    exit 1
}
grep -q '^_pkg_layered ' "$MX_JUSTFILE" || {
    echo "FAIL: _pkg_layered private helper not found in $MX_JUSTFILE"
    exit 1
}

# --- Phase 8: 1Password ujust (single-section repo + key vendored) ---
ONEPW_REPO=/etc/yum.repos.d/1password.repo
ONEPW_GPGKEY=/etc/pki/rpm-gpg/1password.asc
[ -f "$ONEPW_REPO" ] || { echo "FAIL: $ONEPW_REPO missing"; exit 1; }
if grep -q "^enabled=1" "$ONEPW_REPO"; then
    echo "FAIL: $ONEPW_REPO should ship enabled=0 (build-time invariant)"
    exit 1
fi
if [ ! -s "$ONEPW_GPGKEY" ]; then
    echo "FAIL: $ONEPW_GPGKEY missing or empty"
    exit 1
fi
grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----$' "$ONEPW_GPGKEY" || {
    echo "FAIL: $ONEPW_GPGKEY non sembra un PGP key block"
    exit 1
}
grep -q '^install-1password:' "$MX_JUSTFILE" || {
    echo "FAIL: install-1password recipe not found in $MX_JUSTFILE"
    exit 1
}

# --- Phase 8: justfile import nel master Bazzite ---
# Senza questo, ujust non vede 95-bazzite-mx.just (Bazzite ujust ha
# import espliciti, no glob).
MASTER_JUSTFILE=/usr/share/ublue-os/justfile
grep -qxF 'import "/usr/share/ublue-os/just/95-bazzite-mx.just"' "$MASTER_JUSTFILE" || {
    echo "FAIL: 95-bazzite-mx.just non è imported nel master $MASTER_JUSTFILE"
    exit 1
}

# Smoke test definitivo: ujust deve listare entrambe le ricette MX.
# Se uno dei due nomi manca, l'import è broken.
UJUST_LIST=$(ujust --list 2>&1)
echo "$UJUST_LIST" | grep -q 'install-discord' || {
    echo "FAIL: ujust --list non mostra install-discord"
    echo "--- output ---"
    echo "$UJUST_LIST"
    exit 1
}
echo "$UJUST_LIST" | grep -q 'install-1password' || {
    echo "FAIL: ujust --list non mostra install-1password"
    echo "--- output ---"
    echo "$UJUST_LIST"
    exit 1
}

# --- Phase 8: desktop GUI apps (gparted, ptyxis) ---
# 60-desktop-apps.sh installa gparted (rimpiazza kde-partitionmanager
# rimosso da Bazzite) + ptyxis (bare install, no shim/sed integration).
DESKTOP_APPS_RPMS=( gparted ptyxis )
for p in "${DESKTOP_APPS_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || {
        echo "FAIL: rpm $p missing (60-desktop-apps.sh broken?)"
        exit 1
    }
done

# --- Phase 8: vscode-extensions user-setup hook ---
# Hook al primo login utente che pre-installa le 3 extension Microsoft
# container/remote (lista convergente Aurora-DX + Bazzite-DX, verificato
# 2026-05-03). Versioned via libsetup.sh::version-script. Il hook viene
# eseguito sul deployment finale, non in build — qui controlliamo solo
# che il file sia presente, eseguibile, e che non manchi nessuna delle
# 3 extension attese (regression catch).
VSCODE_HOOK=/usr/share/ublue-os/user-setup.hooks.d/11-vscode-extensions.sh
if [ ! -x "$VSCODE_HOOK" ]; then
    echo "FAIL: $VSCODE_HOOK missing or not executable"
    exit 1
fi

VSCODE_EXTENSIONS=(
    ms-vscode-remote.remote-containers
    ms-vscode-remote.remote-ssh
    ms-azuretools.vscode-containers
)
# Greppiamo solo l'ID extension, non `code --install-extension <id>`:
# se domani il hook venisse refactorato a array-loop la sintassi
# cambia ma l'ID resta — il test deve catturare la regression
# semantica ("manca un'extension"), non quella sintattica.
for ext in "${VSCODE_EXTENSIONS[@]}"; do
    grep -qF "$ext" "$VSCODE_HOOK" || {
        echo "FAIL: $VSCODE_HOOK non installa $ext (regression?)"
        exit 1
    }
done

echo "MX smoke tests OK."
echo "::endgroup::"
