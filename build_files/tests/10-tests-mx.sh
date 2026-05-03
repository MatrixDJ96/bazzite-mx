#!/usr/bin/bash
# MX smoke tests. Runs after the build orchestrator, immediately before
# bootc container lint. Blocking: every assertion exits 1 on failure.
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
# image-info.json image-name must reflect the fork.
grep -qE '"image-name":[[:space:]]*"bazzite-mx(-nvidia(-open)?)?"' /usr/share/ublue-os/image-info.json || {
    echo "FAIL: /usr/share/ublue-os/image-info.json image-name not rewritten"
    cat /usr/share/ublue-os/image-info.json
    exit 1
}
# image-vendor must reflect the actual publisher (matrixdj96), not
# the inherited "ublue-os" from Bazzite base (Phase 9 closing).
grep -qE '"image-vendor":[[:space:]]*"matrixdj96"' /usr/share/ublue-os/image-info.json || {
    echo "FAIL: /usr/share/ublue-os/image-info.json image-vendor not rewritten to matrixdj96"
    grep image-vendor /usr/share/ublue-os/image-info.json || true
    exit 1
}
# os-release VARIANT_ID likewise.
grep -qE '^VARIANT_ID=bazzite-mx(-nvidia(-open)?)?$' /usr/lib/os-release || {
    echo "FAIL: /usr/lib/os-release VARIANT_ID not rewritten"
    grep ^VARIANT_ID= /usr/lib/os-release || true
    exit 1
}
# KDE about page (Variant + Website).
# Regex anchored on both ends: matches only the 3 valid strings
# ('Bazzite-MX', 'Bazzite-MX (NVIDIA)', 'Bazzite-MX (NVIDIA Open)') and
# rejects malformed values like 'Bazzite-MX-BROKEN' or 'Bazzite-MXfoo'.
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

# --- Phase 8: Firefox from Mozilla's official RPM repo ---
# The build replaces Bazzite's Flathub flatpak with the Mozilla RPM
# (45-firefox-rpm.sh). Assertions:
#  - firefox + firefox-l10n-it installed
#  - VENDOR = "Mozilla" (guard against regression to the Fedora rpm
#    if it ever gets added to Bazzite base)
FIREFOX_RPMS=( firefox firefox-l10n-it )
for p in "${FIREFOX_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || { echo "FAIL: rpm $p missing"; exit 1; }
done

# The VENDOR field "Mozilla" is the exact string from the Mozilla RPM
# package (verified 2026-05-02 on firefox-150.0.1-1; the Fedora package
# would use "Fedora Project"). Defensive head -1 for the (unlikely on a
# clean build) case of multiple NEVRs installed post-failed-reinstall.
FIREFOX_VENDOR=$(rpm -q firefox --qf '%{VENDOR}\n' | head -1)
if [ "$FIREFOX_VENDOR" != "Mozilla" ]; then
    echo "FAIL: firefox vendor is '$FIREFOX_VENDOR', expected 'Mozilla'"
    exit 1
fi

# --- Phase 8: Firefox flatpak exclusion ---
# 46-firefox-flatpak-exclude.sh patches Bazzite's default-install list
# and extends the Flathub blocklist. Verify both edits took effect.
FIREFOX_INSTALL_LIST=/usr/share/ublue-os/bazzite/flatpak/install
if grep -q '^org\.mozilla\.firefox$' "$FIREFOX_INSTALL_LIST"; then
    echo "FAIL: org.mozilla.firefox still present in $FIREFOX_INSTALL_LIST"
    exit 1
fi

FIREFOX_BLOCKLIST=/usr/share/ublue-os/flatpak-blocklist
if ! grep -q '^deny org\.mozilla\.firefox/\*$' "$FIREFOX_BLOCKLIST"; then
    echo "FAIL: deny org.mozilla.firefox/* not found in $FIREFOX_BLOCKLIST"
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
# Discord is NOT installed by default (it's an opt-in ujust recipe).
# The .repo files + GPG keys come from the rpmfusion-nonfree-release
# package (47-rpmfusion-release.sh) — no static vendoring, future-proof.
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

# The GPG key ships with the rpmfusion-nonfree-release package (together
# with keys for Fedora 45/46/rawhide). We verify that at least the
# current F44 key is in place: without it, the first
# `rpm-ostree install discord` via ujust would prompt the user.
RPMFUSION_GPGKEY=/etc/pki/rpm-gpg/RPM-GPG-KEY-rpmfusion-nonfree-fedora-44
if [ ! -s "$RPMFUSION_GPGKEY" ]; then
    echo "FAIL: $RPMFUSION_GPGKEY missing or empty"
    exit 1
fi
grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----$' "$RPMFUSION_GPGKEY" || {
    echo "FAIL: $RPMFUSION_GPGKEY does not look like a PGP key block"
    exit 1
}

# 95-bazzite-mx.just must exist and ship the install-discord recipe.
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
    echo "FAIL: $ONEPW_GPGKEY does not look like a PGP key block"
    exit 1
}
grep -q '^install-1password:' "$MX_JUSTFILE" || {
    echo "FAIL: install-1password recipe not found in $MX_JUSTFILE"
    exit 1
}

# --- Phase 8: justfile import in Bazzite's master file ---
# Without this, ujust doesn't see 95-bazzite-mx.just (Bazzite's ujust
# uses explicit imports, no glob).
MASTER_JUSTFILE=/usr/share/ublue-os/justfile
grep -qxF 'import "/usr/share/ublue-os/just/95-bazzite-mx.just"' "$MASTER_JUSTFILE" || {
    echo "FAIL: 95-bazzite-mx.just is not imported in master $MASTER_JUSTFILE"
    exit 1
}

# Definitive smoke test: ujust must list both MX recipes.
# If either name is missing, the import is broken.
UJUST_LIST=$(ujust --list 2>&1)
echo "$UJUST_LIST" | grep -q 'install-discord' || {
    echo "FAIL: ujust --list does not show install-discord"
    echo "--- output ---"
    echo "$UJUST_LIST"
    exit 1
}
echo "$UJUST_LIST" | grep -q 'install-1password' || {
    echo "FAIL: ujust --list does not show install-1password"
    echo "--- output ---"
    echo "$UJUST_LIST"
    exit 1
}

# --- Phase 8: desktop GUI apps (gparted, ptyxis) ---
# 60-desktop-apps.sh installs gparted (replaces kde-partitionmanager
# removed by Bazzite) + ptyxis (bare install, no shim/sed integration).
DESKTOP_APPS_RPMS=( gparted ptyxis )
for p in "${DESKTOP_APPS_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || {
        echo "FAIL: rpm $p missing (60-desktop-apps.sh broken?)"
        exit 1
    }
done

# --- Phase 8: vscode-extensions user-setup hook ---
# Hook that runs at first user login and pre-installs the 3 Microsoft
# container/remote extensions (list convergent across Aurora-DX +
# Bazzite-DX, verified 2026-05-03). Versioned via
# libsetup.sh::version-script. The hook runs on the deployed system,
# not at build time — here we only verify the file is present,
# executable, and ships all 3 expected extension IDs (regression catch).
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
# Grep only the extension ID, not `code --install-extension <id>`: if
# the hook is ever refactored to an array-loop, the syntax changes but
# the ID stays — the test should catch the semantic regression
# ("an extension is missing"), not the syntactic one.
for ext in "${VSCODE_EXTENSIONS[@]}"; do
    grep -qF "$ext" "$VSCODE_HOOK" || {
        echo "FAIL: $VSCODE_HOOK does not install $ext (regression?)"
        exit 1
    }
done

echo "MX smoke tests OK."
echo "::endgroup::"
