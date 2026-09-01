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
if [ ! -f /etc/modules-load.d/90-bazzite-mx-nat.conf ]; then
    echo "FAIL: missing /etc/modules-load.d/90-bazzite-mx-nat.conf"
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
grep -qE '"image-ref":[[:space:]]*"ostree-image-signed:docker://ghcr.io/matrixdj96/bazzite-mx(-nvidia(-open)?)?"' /usr/share/ublue-os/image-info.json || {
    echo "FAIL: /usr/share/ublue-os/image-info.json image-ref not rewritten"
    grep image-ref /usr/share/ublue-os/image-info.json || true
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
    podman-compose podman-machine podman-tui bcvk
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
    qemu-img qemu-kvm qemu-system-x86-core
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

# --- Phase 4: packages that must NOT be in the image ---
# Every rpm -q above proves presence; nothing proved absence, and weak
# dependencies are a live reintroduction channel. `qemu` is the full-emulator
# metapackage 20-virtualization.sh deliberately leaves out; `podman-bootc` is
# the package that used to drag it in (gotcha #23) and was replaced by bcvk.
NEGATIVE_RPMS=( qemu podman-bootc )
for p in "${NEGATIVE_RPMS[@]}"; do
    if rpm -q "$p" >/dev/null 2>&1; then
        echo "FAIL: rpm $p is installed (deliberately excluded; pulled in as a dependency?)"
        exit 1
    fi
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

# --- Phase 4: KVM module options (kvm.ignore_msrs / kvm.report_ignored_msrs) ---
# Shipped as modprobe.d options: kmod applies them at every kvm.ko load on
# any deployment kind. A bootc kargs.d TOML reaches only bootc-managed
# deployments (rpm-ostree never reads /usr/lib/bootc/kargs.d), so the
# modprobe.d file is the single source of the KVM tuning.
KVM_MODPROBE_FILE=/usr/lib/modprobe.d/bazzite-mx-kvm.conf
if [ ! -f "$KVM_MODPROBE_FILE" ]; then
    echo "FAIL: $KVM_MODPROBE_FILE missing"
    exit 1
fi
grep -qE '^options kvm ignore_msrs=1 report_ignored_msrs=0$' "$KVM_MODPROBE_FILE" || {
    echo "FAIL: $KVM_MODPROBE_FILE missing 'options kvm ignore_msrs=1 report_ignored_msrs=0'"
    exit 1
}
if [ -e /usr/lib/bootc/kargs.d/01-bazzite-mx-virt.toml ]; then
    echo "FAIL: stale KVM kargs.d TOML shipped alongside the modprobe.d options"
    exit 1
fi

# --- Phase 4: setup-virtualization override (unified mechanism) ---
# Our recipe lives in 96-bazzite-mx-overrides.just; the reconcile step strips the
# upstream copy from 84-bazzite-virt.just. Exactly one definition must remain.
OVERRIDE_JUSTFILE=/usr/share/ublue-os/just/96-bazzite-mx-overrides.just
if [ ! -f "$OVERRIDE_JUSTFILE" ]; then
    echo "FAIL: $OVERRIDE_JUSTFILE missing"
    exit 1
fi
# `|| true`: with no match grep exits 1 and, under pipefail, would kill the
# script with no FAIL line; the string compare then reports a zero count.
vcount=$(grep -rlE '^setup-virtualization[ :]' /usr/share/ublue-os/just/ | wc -l || true)
[ "${vcount:-}" = "1" ] || { echo "FAIL: setup-virtualization defined in '${vcount:-<no reading>}' files (expected 1)"; exit 1; }
grep -qE '^setup-virtualization[ :]' "$OVERRIDE_JUSTFILE" || {
    echo "FAIL: setup-virtualization not found in $OVERRIDE_JUSTFILE"
    exit 1
}
# The upstream file must exist for the negative assertion to mean anything:
# grep on a missing file exits non-zero and would pass it silently.
[ -f /usr/share/ublue-os/just/84-bazzite-virt.just ] || {
    echo "FAIL: upstream 84-bazzite-virt.just missing (base renamed it? the negative check below would be vacuous)"
    exit 1
}
if grep -qE '^setup-virtualization[ :]' /usr/share/ublue-os/just/84-bazzite-virt.just; then
    echo "FAIL: setup-virtualization still present in upstream 84-bazzite-virt.just (reconcile removal failed)"
    exit 1
fi
if grep -qE '^[[:space:]]*flatpak install.*org\.virt_manager\.virt-manager' "$OVERRIDE_JUSTFILE"; then
    echo "FAIL: $OVERRIDE_JUSTFILE contains a residual 'flatpak install' line for virt-manager"
    exit 1
fi
# Three idioms a re-sync from bazzite-dx would silently reintroduce, each one a
# revert that reports success while leaving state behind (gotchas #29, #30, #31).
# The recipe's comments quote those idioms on purpose, so the assertions read the
# code lines only.
OVERRIDE_CODE=$(grep -vE '^[[:space:]]*#' "$OVERRIDE_JUSTFILE")
if grep -qE 'delete-if-present=\\"' <<< "$OVERRIDE_CODE"; then
    echo "FAIL: $OVERRIDE_JUSTFILE builds a --delete-if-present argument as a quoted string"
    exit 1
fi
if grep -qE "sed -E 's/\.\+\((vfio_pci|kvmfr)" <<< "$OVERRIDE_CODE"; then
    echo "FAIL: $OVERRIDE_JUSTFILE extracts a host-specific karg with the position-sensitive sed"
    exit 1
fi
if grep -qE '^[[:space:]]*rpm-ostree initramfs --enable' <<< "$OVERRIDE_CODE"; then
    echo "FAIL: $OVERRIDE_JUSTFILE calls 'rpm-ostree initramfs --enable' in vfio-on"
    exit 1
fi
# kvmfr branch helper (vendored byte-identical from bazzite-dx, divergence #4):
# the recipe sudo-invokes it, so a dropped file or lost +x fails only at runtime
[ -x /usr/libexec/bazzite-dx-kvmfr-setup ] || {
    echo "FAIL: /usr/libexec/bazzite-dx-kvmfr-setup missing or not executable"
    exit 1
}
grep -q 'bazzite-dx-kvmfr-setup' "$OVERRIDE_JUSTFILE" || {
    echo "FAIL: setup-virtualization override does not reference bazzite-dx-kvmfr-setup"
    exit 1
}

# --- Phase 4: virt-manager flatpak blocklist (21-virt-manager-flatpak-exclude.sh) ---
FLATPAK_BLOCKLIST=/usr/share/ublue-os/flatpak-blocklist
grep -q '^deny org\.virt_manager\.virt-manager/\*$' "$FLATPAK_BLOCKLIST" || {
    echo "FAIL: $FLATPAK_BLOCKLIST missing virt-manager deny line"
    exit 1
}

# --- Phase 4: virt-manager flatpak cleanup hooks ---
VIRT_HOOK_SYSTEM=/usr/share/ublue-os/system-setup.hooks.d/16-bazzite-mx-virt-manager-flatpak-cleanup.sh
VIRT_HOOK_USER=/usr/share/ublue-os/user-setup.hooks.d/16-bazzite-mx-virt-manager-flatpak-cleanup.sh
if [ ! -x "$VIRT_HOOK_SYSTEM" ]; then
    echo "FAIL: $VIRT_HOOK_SYSTEM missing or not executable"
    exit 1
fi
if [ ! -x "$VIRT_HOOK_USER" ]; then
    echo "FAIL: $VIRT_HOOK_USER missing or not executable"
    exit 1
fi
# Content, not just mode: each hook must still uninstall the flatpak it is
# named after (same idiom as the vscode-extensions hook check below).
for hook in "$VIRT_HOOK_SYSTEM" "$VIRT_HOOK_USER"; do
    grep -qE '^flatpak uninstall .*org\.virt_manager\.virt-manager' "$hook" || {
        echo "FAIL: $hook does not uninstall org.virt_manager.virt-manager"
        exit 1
    }
done

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
    ripgrep
    cosign # shipped by the Bazzite base; asserted because image verification relies on it
)
for p in "${DEV_CLI_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || { echo "FAIL: rpm $p missing"; exit 1; }
done

# --- Phase 6: CLI binaries from official releases (41-dev-cli-pinned.sh) ---
CLI_BINARIES=( gh glab shellcheck shfmt )
for b in "${CLI_BINARIES[@]}"; do
    [ -x "/usr/bin/$b" ] || { echo "FAIL: /usr/bin/$b missing or not executable"; exit 1; }
done

# --- Phase 7: Firefox from Mozilla's official RPM repo ---
# The build replaces Bazzite's Flathub flatpak with the Mozilla RPM
# (61-firefox-rpm.sh). Assertions:
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
FIREFOX_HOOK_SYS=/usr/share/ublue-os/system-setup.hooks.d/15-bazzite-mx-firefox-flatpak-cleanup.sh
FIREFOX_HOOK_USER=/usr/share/ublue-os/user-setup.hooks.d/15-bazzite-mx-firefox-flatpak-cleanup.sh
if [ ! -x "$FIREFOX_HOOK_SYS" ]; then
    echo "FAIL: $FIREFOX_HOOK_SYS missing or not executable"
    exit 1
fi
if [ ! -x "$FIREFOX_HOOK_USER" ]; then
    echo "FAIL: $FIREFOX_HOOK_USER missing or not executable"
    exit 1
fi
for hook in "$FIREFOX_HOOK_SYS" "$FIREFOX_HOOK_USER"; do
    grep -qE '^flatpak uninstall .*org\.mozilla\.firefox' "$hook" || {
        echo "FAIL: $hook does not uninstall org.mozilla.firefox"
        exit 1
    }
done

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
    echo "FAIL: $ONEPW_GPGKEY missing or empty (64-1password-key.sh broken?)"
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
# 50-bazzite-extras.sh enables it --global: if that regressed, every user hook
# (vscode extensions, firefox/virt-manager cleanups) would silently never run
user_setup_state=$(systemctl --global is-enabled ublue-user-setup.service 2>/dev/null || echo missing)
if [ "$user_setup_state" != "enabled" ]; then
    echo "FAIL: ublue-user-setup.service not globally enabled (state=$user_setup_state)"
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

# --- Phase 9: hook-directory contract (dispatchers <-> our hook paths) ---
# /usr/libexec/ublue-{system,user}-setup come from the unpinned ublue-os/packages
# COPR and resolve their hooks directory through get_config, defaulting to
# /usr/share/ublue-os/{system,user}-setup.hooks.d. Every other assertion here
# only proves OUR files sit at those paths; nothing proved the dispatchers still
# read them. A renamed default, or a setup.json that redirects them, leaves every
# hook (groups, vscode extensions, firefox/virt-manager cleanups) silently
# unexecuted on a green build.
for pair in "system:/usr/share/ublue-os/system-setup.hooks.d" \
            "user:/usr/share/ublue-os/user-setup.hooks.d"; do
    disp="/usr/libexec/ublue-${pair%%:*}-setup"
    hooks_dir="${pair#*:}"
    [ -x "$disp" ] || { echo "FAIL: $disp missing or not executable"; exit 1; }
    grep -qF "$hooks_dir" "$disp" || {
        echo "FAIL: $disp does not name $hooks_dir (hooks directory renamed upstream)"
        exit 1
    }
done
# The dispatchers read /etc/ublue-os/setup.json when it exists. Neither we nor
# the base ship one today; if one appears it may not point elsewhere.
SETUP_JSON=/etc/ublue-os/setup.json
if [ -f "$SETUP_JSON" ]; then
    for key_dir in "system-hooks-directory:/usr/share/ublue-os/system-setup.hooks.d" \
                   "user-hooks-directory:/usr/share/ublue-os/user-setup.hooks.d"; do
        key="${key_dir%%:*}"
        want="${key_dir#*:}"
        got=$(jq -r --arg k "$key" '.[$k] // "null"' "$SETUP_JSON")
        if [ "$got" != "null" ] && [ "$got" != "$want" ]; then
            echo "FAIL: $SETUP_JSON redirects $key to '$got' (our hooks live in $want)"
            exit 1
        fi
    done
fi

# --- Phase 9: every group the hook grants is created by systemd-sysusers ---
# The hook's /usr/lib/group merge is dead on this base -- upstream's
# relocate_accounts runs before our docker-ce/libvirt installs, so /etc/group
# carries both and /usr/lib/group neither (MEASURED 2026-09-01). What actually
# creates them at boot is sysusers.d: docker from our own file (docker-ce's
# `groupadd` scriptlet is suppressed on rpm-ostree), libvirt from libvirt's
# libvirt.conf. A group with no sysusers entry would be granted to nobody.
for g in docker libvirt; do
    grep -rqE "^g[[:space:]]+${g}[[:space:]]" /usr/lib/sysusers.d/ || {
        echo "FAIL: no /usr/lib/sysusers.d entry creates the '$g' group"
        exit 1
    }
done

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
grep -q '^install-1password:' "$MX_JUSTFILE" || {
    echo "FAIL: install-1password recipe not found in $MX_JUSTFILE"
    exit 1
}
grep -q '^_pkg_layered ' "$MX_JUSTFILE" || {
    echo "FAIL: _pkg_layered private helper not found in $MX_JUSTFILE"
    exit 1
}
grep -q '^reset-repos:' "$MX_JUSTFILE" || {
    echo "FAIL: reset-repos recipe not found in $MX_JUSTFILE"
    exit 1
}
grep -q "import \"/usr/share/ublue-os/just/95-bazzite-mx.just\"" /usr/share/ublue-os/justfile || {
    echo "FAIL: import line for 95-bazzite-mx.just missing from master justfile"
    exit 1
}
grep -q "import \"/usr/share/ublue-os/just/96-bazzite-mx-overrides.just\"" /usr/share/ublue-os/justfile || {
    echo "FAIL: import line for 96-bazzite-mx-overrides.just missing from master justfile"
    exit 1
}

# --- Phase 10: master justfile parses with its whole import tree ---
# Catches a logically corrupted rewrite (surgical removal gone wrong, broken
# import) at build time. NOTE: this is a warm page-cache read and cannot see
# torn writeback - the post-rechunk check-image-integrity.sh in
# reusable-build.yml is the one that reads cold. The exit status is just's
# own, never piped.
just --unstable --justfile /usr/share/ublue-os/justfile --summary > /dev/null || {
    echo "FAIL: master justfile does not parse (broken rewrite or import)"
    exit 1
}

# --- Phase 10: every justfile world-readable (ujust runs unprivileged) ---
# The reconcile rewrite must keep the base image's 0644 on every stripped
# justfile: a root-only file makes `ujust` fail with Permission denied for
# regular users on the whole imported tree, not just the stripped file.
UNREADABLE_JUST=$(find /usr/share/ublue-os/just/ /usr/share/ublue-os/justfile ! -perm -o+r 2>/dev/null || true)
if [ -n "$UNREADABLE_JUST" ]; then
    echo "FAIL: justfiles not world-readable (ujust breaks for unprivileged users):"
    echo "$UNREADABLE_JUST"
    exit 1
fi

# --- Phase 11: Desktop apps (gparted + ptyxis) ---
DESKTOP_RPMS=( gparted ptyxis )
for p in "${DESKTOP_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || { echo "FAIL: rpm $p missing"; exit 1; }
done

# --- Phase 11: vscode-extensions user-setup hook ---
VSCODE_HOOK=/usr/share/ublue-os/user-setup.hooks.d/11-bazzite-mx-vscode-extensions.sh
if [ ! -x "$VSCODE_HOOK" ]; then
    echo "FAIL: $VSCODE_HOOK missing or not executable"
    exit 1
fi
VSCODE_EXTENSIONS=(
    ms-vscode-remote.remote-containers
    ms-vscode-remote.remote-ssh
    ms-azuretools.vscode-containers
)
for ext in "${VSCODE_EXTENSIONS[@]}"; do
    grep -qF "$ext" "$VSCODE_HOOK" || {
        echo "FAIL: $VSCODE_HOOK does not install $ext (regression?)"
        exit 1
    }
done

# --- Phase 12: Sunshine reintegration (build-time RPM, opt-in user service) ---
# The pvermeer/sunshine community COPR ships the rpm as lowercase `sunshine`
# with %caps(cap_sys_admin,cap_sys_nice+p) on the binary and a spec-guaranteed
# `sunshine.service` alias for the LizardByte-named user unit.
rpm -q sunshine >/dev/null || {
    echo "FAIL: sunshine rpm missing (65-sunshine.sh broken? COPR offline?)"
    exit 1
}
SUNSHINE_BIN=$(readlink -f /usr/bin/sunshine)
SUNSHINE_CAPS=$(getcap "$SUNSHINE_BIN" 2>/dev/null || true)
for cap in cap_sys_admin cap_sys_nice; do
    case "$SUNSHINE_CAPS" in
        *"$cap"*) ;;
        *)
            echo "FAIL: $SUNSHINE_BIN missing $cap (getcap output: '$SUNSHINE_CAPS')"
            exit 1
            ;;
    esac
done
[ -e /usr/lib/systemd/user/sunshine.service ] || {
    echo "FAIL: sunshine.service alias missing (pvermeer spec guarantees it)"
    exit 1
}
SUNSHINE_UNIT=app-dev.lizardbyte.app.Sunshine.service
sun_state=$(systemctl --global is-enabled "$SUNSHINE_UNIT" 2>/dev/null || true)
if [ -z "$sun_state" ]; then
    echo "FAIL: $SUNSHINE_UNIT lookup returned empty stdout"
    exit 1
fi
if [ "$sun_state" != "disabled" ]; then
    echo "FAIL: $SUNSHINE_UNIT --global state is '$sun_state' (expected 'disabled')"
    exit 1
fi
# setup-sunshine override lives in 96; reconcile strips the upstream copy.
scount=$(grep -rlE '^setup-sunshine[ :]' /usr/share/ublue-os/just/ | wc -l || true)
[ "${scount:-}" = "1" ] || { echo "FAIL: setup-sunshine defined in '${scount:-<no reading>}' files (expected 1)"; exit 1; }
grep -qE '^setup-sunshine[ :]' "$OVERRIDE_JUSTFILE" || {
    echo "FAIL: setup-sunshine not found in $OVERRIDE_JUSTFILE"
    exit 1
}
[ -f /usr/share/ublue-os/just/82-bazzite-sunshine.just ] || {
    echo "FAIL: upstream 82-bazzite-sunshine.just missing (base renamed it? the negative check below would be vacuous)"
    exit 1
}
if grep -qE '^setup-sunshine[ :]' /usr/share/ublue-os/just/82-bazzite-sunshine.just; then
    echo "FAIL: setup-sunshine still present in upstream 82-bazzite-sunshine.just (reconcile removal failed)"
    exit 1
fi
# Code lines only ($OVERRIDE_CODE strips comment lines, indented ones included):
# the recipe's comments name the flatpak on purpose.
if grep -q 'homebrew\.sunshine' <<< "$OVERRIDE_CODE"; then
    echo "FAIL: $OVERRIDE_JUSTFILE contains a residual 'homebrew.sunshine' reference outside comments"
    exit 1
fi
SUNSHINE_NAG=/usr/share/ublue-os/announcements/sunshine-brew.msg.json
if [ -f "$SUNSHINE_NAG" ]; then
    echo "FAIL: $SUNSHINE_NAG should have been removed by 65-sunshine.sh"
    exit 1
fi
# virtual-monitor action (ported from bazzite 55e6e852): helpers shipped
# executable, recipe carries the action that references them
for s in /usr/libexec/sunshine-start-vmon /usr/libexec/sunshine-stop-vmon; do
    [ -x "$s" ] || { echo "FAIL: $s missing or not executable"; exit 1; }
done
grep -q 'krfb-virtualmonitor' /usr/libexec/sunshine-start-vmon || {
    echo "FAIL: sunshine-start-vmon does not reference krfb-virtualmonitor"
    exit 1
}
grep -q 'virtual-monitor' "$OVERRIDE_JUSTFILE" || {
    echo "FAIL: setup-sunshine override carries no virtual-monitor action"
    exit 1
}

# --- Phase 12: Bazzite Portal option coverage (yafti.yml -> override chains) ---
# The shipped image autostarts the Portal
# (/etc/skel/.config/autostart/bazzite-portal.desktop, yafti), which drives our
# two overridden recipes through /usr/share/yafti/yafti.yml. Upstream adds and
# renames those buttons on its own schedule, and an option we never reviewed
# reaches a recipe that either does the wrong thing (an unanchored regex: a
# 'enable-beta' button ran the plain RPM enable path) or lands in a catch-all
# whose message was written for a different action. Fail at build time on any
# token outside the reviewed set.
YAFTI=/usr/share/yafti/yafti.yml
[ -f "$YAFTI" ] || { echo "FAIL: $YAFTI missing (Bazzite Portal layout changed?)"; exit 1; }
declare -A YAFTI_KNOWN=(
    [setup-sunshine]="disable enable enable-beta portal status uninstall update virtual-monitor"
    [setup-virtualization]="virt-off virt-on"
)
for recipe in "${!YAFTI_KNOWN[@]}"; do
    mapfile -t seen < <(grep -oE "ujust $recipe [a-z][a-z-]*" "$YAFTI" | awk '{print $3}' | sort -u)
    [ "${#seen[@]}" -gt 0 ] || {
        echo "FAIL: $YAFTI drives no '$recipe' action (recipe renamed upstream?)"
        exit 1
    }
    for opt in "${seen[@]}"; do
        case " ${YAFTI_KNOWN[$recipe]} " in
            *" $opt "*) ;;
            *)
                echo "FAIL: $YAFTI offers 'ujust $recipe $opt', an option this image has never reviewed"
                echo "      reviewed: ${YAFTI_KNOWN[$recipe]}"
                exit 1
                ;;
        esac
    done
    echo "yafti $recipe options reviewed: ${seen[*]}"
done
# Both chains must keep their catch-all: a re-sync from upstream that drops it
# restores the silent exit-0 the Portal reads as success.
# grep -c prints 0 and exits 1 when it matches nothing, which under `set -e`
# would kill the script with no FAIL line at all; `|| true` keeps the printed
# value, and the string compare treats an empty reading (unreadable file) as a
# failure rather than crashing on an integer test.
nsupp=$(grep -c "is not supported on bazzite-mx" "$OVERRIDE_JUSTFILE" || true)
[ "${nsupp:-}" = "2" ] || {
    echo "FAIL: $OVERRIDE_JUSTFILE carries '${nsupp:-<no reading>}' unsupported-option branches (expected 2)"
    exit 1
}

# --- Phase 5: install-jetbrains-toolbox non-brew override ---
# Bazzite ships a brew-based recipe in 82-bazzite-apps.just; bazzite-mx replaces it
# with the non-brew Aurora/Bluefin method in 96. Exactly one definition, ours, no brew.
jcount=$(grep -rlE '^install-jetbrains-toolbox[ :]' /usr/share/ublue-os/just/ | wc -l || true)
[ "${jcount:-}" = "1" ] || { echo "FAIL: install-jetbrains-toolbox defined in '${jcount:-<no reading>}' files (expected 1)"; exit 1; }
grep -qE '^install-jetbrains-toolbox[ :]' "$OVERRIDE_JUSTFILE" || {
    echo "FAIL: install-jetbrains-toolbox not found in $OVERRIDE_JUSTFILE"
    exit 1
}
[ -f /usr/share/ublue-os/just/82-bazzite-apps.just ] || {
    echo "FAIL: upstream 82-bazzite-apps.just missing (base renamed it? the negative check below would be vacuous)"
    exit 1
}
if grep -qE '^install-jetbrains-toolbox[ :]' /usr/share/ublue-os/just/82-bazzite-apps.just; then
    echo "FAIL: brew install-jetbrains-toolbox still present in upstream 82-bazzite-apps.just (reconcile removal failed)"
    exit 1
fi
grep -q 'data.services.jetbrains.com' "$OVERRIDE_JUSTFILE" || {
    echo "FAIL: jetbrains recipe in $OVERRIDE_JUSTFILE does not use the JetBrains data-services API (non-brew method missing)"
    exit 1
}
if grep -rqE 'brew install --cask jetbrains-toolbox' /usr/share/ublue-os/just/; then
    echo "FAIL: a brew-based jetbrains-toolbox recipe is still present image-wide"
    exit 1
fi

# --- Phase 16: msi-ec out-of-tree module (build-time, opt-in) ---
MSI_KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core | head -1)
MSI_EC_KO="/usr/lib/modules/${MSI_KVER}/updates/drivers/platform/x86/msi-ec.ko.xz"
if [ ! -f "$MSI_EC_KO" ]; then
    echo "FAIL: $MSI_EC_KO missing (msi-ec build/install broken?)"
    exit 1
fi
# modules.dep must resolve msi-ec to the updates/ copy, not the in-tree kernel/ one
msi_ec_path=$(modinfo -k "$MSI_KVER" -F filename msi-ec 2>/dev/null || true)
case "$msi_ec_path" in
    */updates/*) ;;
    *) echo "FAIL: msi-ec resolves to '$msi_ec_path' (expected …/updates/…; in-tree not overridden)"; exit 1 ;;
esac
# vermagic must match the image's kernel exactly, or modprobe refuses the module
msi_ec_vermagic=$(modinfo -k "$MSI_KVER" -F vermagic msi-ec 2>/dev/null || true)
case "$msi_ec_vermagic" in
    "$MSI_KVER "*) ;;
    *) echo "FAIL: msi-ec vermagic '$msi_ec_vermagic' does not match kernel $MSI_KVER"; exit 1 ;;
esac
# the installed module must be the upstream build that whitelists the device EC firmware.
# Decompress to a temp file first, then grep -a: a `xz -dc | grep -q` pipe trips
# `set -o pipefail` because grep -q exits on first match, SIGPIPEs xz, and xz's
# resulting non-zero status reads as a false failure. (grep -a also avoids
# depending on `strings`, which the final image may not ship.)
msi_ec_tmp=$(mktemp)
xz -dc "$MSI_EC_KO" > "$msi_ec_tmp" 2>/dev/null || true
if ! grep -aqF '17L5EMS1.115' "$msi_ec_tmp"; then
    rm -f "$msi_ec_tmp"
    echo "FAIL: installed msi-ec lacks firmware id 17L5EMS1.115 (stale/wrong source)"
    exit 1
fi
rm -f "$msi_ec_tmp"
# the .ko.xz MUST be CRC32-checked: the kernel's module XZ decompressor rejects
# the default CRC64 stream at modprobe ("decompression failed"). userspace xz
# decompresses either, so this is the only build-time guard against that class.
if ! LC_ALL=C xz --list "$MSI_EC_KO" 2>/dev/null | grep -q 'CRC32'; then
    echo "FAIL: $MSI_EC_KO is not CRC32-compressed (kernel cannot decompress it at modprobe)"
    LC_ALL=C xz --list "$MSI_EC_KO" 2>&1 || true
    exit 1
fi
# opt-in invariant: the image ships NO EC-module autoload (only `ujust setup-msi
# enable` adds /etc/modules-load.d/bazzite-mx-msi.conf at runtime)
shopt -s nullglob
ec_autoload=(
    /usr/lib/modules-load.d/*{msi-ec,acpi_ec,bazzite-mx-msi}*
    /etc/modules-load.d/*{msi-ec,acpi_ec,bazzite-mx-msi}*
)
shopt -u nullglob
if [ "${#ec_autoload[@]}" -gt 0 ]; then
    echo "FAIL: an EC-module modules-load.d autoload is shipped (breaks opt-in)"
    exit 1
fi
# ujust recipe present (MX_JUSTFILE defined in the Phase 10 block above)
grep -q '^setup-msi ' "$MX_JUSTFILE" || {
    echo "FAIL: setup-msi recipe missing from $MX_JUSTFILE"
    exit 1
}

# --- Phase 17: acpi_ec out-of-tree module (build-time, opt-in) ---
# acpi_ec creates the root-only /dev/ec chardev (fan RPM + curves for
# MControlCenter). Unlike msi-ec there is no in-tree copy, but it still
# ships under updates/.
ACPI_EC_KO="/usr/lib/modules/${MSI_KVER}/updates/drivers/acpi/acpi_ec.ko.xz"
if [ ! -f "$ACPI_EC_KO" ]; then
    echo "FAIL: $ACPI_EC_KO missing (acpi_ec build/install broken?)"
    exit 1
fi
acpi_ec_path=$(modinfo -k "$MSI_KVER" -F filename acpi_ec 2>/dev/null || true)
case "$acpi_ec_path" in
    */updates/*) ;;
    *) echo "FAIL: acpi_ec resolves to '$acpi_ec_path' (expected …/updates/…)"; exit 1 ;;
esac
# vermagic must match the image's kernel exactly, or modprobe refuses the module
acpi_ec_vermagic=$(modinfo -k "$MSI_KVER" -F vermagic acpi_ec 2>/dev/null || true)
case "$acpi_ec_vermagic" in
    "$MSI_KVER "*) ;;
    *) echo "FAIL: acpi_ec vermagic '$acpi_ec_vermagic' does not match kernel $MSI_KVER"; exit 1 ;;
esac
# same CRC32 invariant as msi-ec: the kernel XZ module decompressor rejects CRC64
if ! LC_ALL=C xz --list "$ACPI_EC_KO" 2>/dev/null | grep -q 'CRC32'; then
    echo "FAIL: $ACPI_EC_KO is not CRC32-compressed (kernel cannot decompress it at modprobe)"
    LC_ALL=C xz --list "$ACPI_EC_KO" 2>&1 || true
    exit 1
fi

# --- Phase 18: MControlCenter GUI (opt-in via ujust setup-msi) ---
MCC_REPO=/etc/yum.repos.d/teackot-msi.repo
if [ ! -f "$MCC_REPO" ]; then
    echo "FAIL: $MCC_REPO missing (teackot/msi COPR repofile not vendored)"
    exit 1
fi
if grep -q "^enabled=1" "$MCC_REPO"; then
    echo "FAIL: $MCC_REPO should be enabled=0 (runtime-enabled by ujust setup-msi)"
    exit 1
fi
# the GUI install is folded into setup-msi (no standalone install-mcontrolcenter)
grep -q 'rpm-ostree install -y mcontrolcenter' "$MX_JUSTFILE" || {
    echo "FAIL: setup-msi no longer layers mcontrolcenter in $MX_JUSTFILE"
    exit 1
}

# --- Phase 19: bootc install defaults (root-fs-type) ---
BOOTC_INSTALL_FILE=/usr/lib/bootc/install/01-bazzite-mx.toml
if [ ! -f "$BOOTC_INSTALL_FILE" ]; then
    echo "FAIL: $BOOTC_INSTALL_FILE missing"
    exit 1
fi
grep -qF 'root-fs-type = "btrfs"' "$BOOTC_INSTALL_FILE" || {
    echo "FAIL: $BOOTC_INSTALL_FILE does not set root-fs-type=btrfs"
    exit 1
}

# --- Phase 20: ntfsplus out-of-tree module (build-time, loaded on demand) ---
# Linux 7.1's in-tree NTFSPLUS driver (fs/ntfs), built out-of-tree because the ogc
# kernel sets CONFIG_NTFS_FS off. MSI_KVER is the kernel version resolved in the
# Phase 16 block above.
NTFS_KO="/usr/lib/modules/${MSI_KVER}/updates/fs/ntfs/ntfs.ko.xz"
if [ ! -f "$NTFS_KO" ]; then
    echo "FAIL: $NTFS_KO missing (ntfsplus build/install broken?)"
    exit 1
fi
ntfs_path=$(modinfo -k "$MSI_KVER" -F filename ntfs 2>/dev/null || true)
case "$ntfs_path" in
    */updates/*) ;;
    *) echo "FAIL: ntfs resolves to '$ntfs_path' (expected …/updates/…)"; exit 1 ;;
esac
# the module must declare the fs-ntfs alias: that is what makes the kernel load it
# on demand at `mount -i -t ntfs`, and it is also the proof the build produced the
# NTFSPLUS driver rather than an empty object (gotcha #25 fails silently otherwise)
ntfs_alias=$(modinfo -k "$MSI_KVER" -F alias ntfs 2>/dev/null || true)
if [ "$ntfs_alias" != "fs-ntfs" ]; then
    echo "FAIL: ntfs declares alias '$ntfs_alias' (expected fs-ntfs)"
    exit 1
fi
# vermagic must match the image's kernel exactly, or modprobe refuses the module
ntfs_vermagic=$(modinfo -k "$MSI_KVER" -F vermagic ntfs 2>/dev/null || true)
case "$ntfs_vermagic" in
    "$MSI_KVER "*) ;;
    *) echo "FAIL: ntfs vermagic '$ntfs_vermagic' does not match kernel $MSI_KVER"; exit 1 ;;
esac
# same CRC32 invariant as the EC modules: the kernel XZ decompressor rejects CRC64
if ! LC_ALL=C xz --list "$NTFS_KO" 2>/dev/null | grep -q 'CRC32'; then
    echo "FAIL: $NTFS_KO is not CRC32-compressed (kernel cannot decompress it at modprobe)"
    LC_ALL=C xz --list "$NTFS_KO" 2>&1 || true
    exit 1
fi
# ntfsplus coexists with ntfs3, it does not replace it: existing installs mount
# their NTFS volumes with `ntfs3` in fstab and must keep working across an upgrade
ntfs3_path=$(modinfo -k "$MSI_KVER" -F filename ntfs3 2>/dev/null || true)
if [ -z "$ntfs3_path" ]; then
    echo "FAIL: in-tree ntfs3 no longer resolves (ntfsplus must coexist, not replace)"
    exit 1
fi
# no autoload ships: the kernel loads a filesystem module on demand at mount time
shopt -s nullglob
ntfs_autoload=(
    /usr/lib/modules-load.d/*ntfs*
    /etc/modules-load.d/*ntfs*
)
shopt -u nullglob
if [ "${#ntfs_autoload[@]}" -gt 0 ]; then
    echo "FAIL: an ntfs modules-load.d autoload is shipped (the mount itself loads the driver)"
    exit 1
fi
# the two generic mount.ntfs helpers are gone: while they exist, mount(8) routes
# every `mount -t ntfs` — fstab lines and systemd .mount units included — to
# mount.ntfs-3g and the kernel driver is never reached (gotcha #26)
NTFS_MOUNT_HELPERS=(
    /usr/sbin/mount.ntfs
    /usr/bin/mount.ntfs
)
for h in "${NTFS_MOUNT_HELPERS[@]}"; do
    if [ -e "$h" ] || [ -L "$h" ]; then
        echo "FAIL: $h still present ($(readlink -f "$h" 2>/dev/null || echo '?')) — fstab type ntfs would reach FUSE"
        exit 1
    fi
done
# the FUSE escape hatch stays: `mount -t ntfs-3g` keeps working for anyone who
# wants ntfs-3g explicitly, and libguestfs-appliance keeps its dependency
NTFS_3G_KEEP=(
    /usr/sbin/mount.ntfs-3g
    /usr/bin/ntfs-3g
)
for p in "${NTFS_3G_KEEP[@]}"; do
    if [ ! -x "$p" ]; then
        echo "FAIL: $p missing (the ntfs-3g escape hatch must survive the helper removal)"
        exit 1
    fi
done
# proof the helpers went away by deletion and not by dropping the package
NTFS_3G_RPMS=( ntfs-3g libguestfs-appliance )
for p in "${NTFS_3G_RPMS[@]}"; do
    rpm -q "$p" >/dev/null || { echo "FAIL: rpm $p missing"; exit 1; }
done

# --- Phase 21: kernel image vs modules directory coherence ---
# The vermagic checks above prove each MODULE matches its directory; this one
# proves the KERNEL does too: UTS_RELEASE read out of vmlinuz (x86 boot
# protocol: "HdrS" magic at offset 514, kernel_version pointer at 526) must
# equal the /usr/lib/modules/<kver> directory name. Catches the base/akmods
# split failing on the kernel itself — a kernel packaged under a directory it
# was not built as loads no module at all, in-tree included (gotcha #33).
# Ported from bazzite ad0ead78 (goss kernel_modules_match_uname).
vml_found=0
for dir in /usr/lib/modules/*/; do
    kver="${dir%/}"; kver="${kver##*/}"
    vmlinuz="${dir}vmlinuz"
    [ -f "$vmlinuz" ] || continue
    vml_found=$((vml_found + 1))
    if [ "$(dd if="$vmlinuz" bs=1 skip=514 count=4 2>/dev/null)" != "HdrS" ]; then
        echo "FAIL: $vmlinuz carries no x86 boot header (HdrS) — cannot read UTS_RELEASE"
        exit 1
    fi
    off=$(od -An -tu2 -j 526 -N 2 "$vmlinuz" 2>/dev/null | tr -d ' ')
    if [ -z "$off" ] || [ "$off" = "0" ]; then
        echo "FAIL: $vmlinuz has no kernel_version pointer, cannot read UTS_RELEASE"
        exit 1
    fi
    uts=$(dd if="$vmlinuz" bs=1 skip=$((512 + off)) count=200 2>/dev/null | tr '\0' '\n' | head -n1)
    uts="${uts%% *}"
    if [ "$uts" != "$kver" ]; then
        echo "FAIL: $vmlinuz boots as '$uts' but its modules live in /usr/lib/modules/$kver"
        exit 1
    fi
done
[ "$vml_found" -gt 0 ] || { echo "FAIL: no vmlinuz found under /usr/lib/modules"; exit 1; }

# --- Phase 22: runtime scratch directories keep their base-image modes ---
# clean-stage.sh deletes and recreates /var/tmp; mkdir's 0755 is not what a
# world-writable sticky directory needs, and a booted host hides the mistake
# because systemd-tmpfiles repairs it on the way up.
for d in /var/tmp /tmp; do
    mode=$(stat -c '%a' "$d")
    if [ "$mode" != "1777" ]; then
        echo "FAIL: $d is mode $mode (expected 1777)"
        exit 1
    fi
done

# --- Phase 21: clean-stage.sh residue ---
# build.sh raises dnf's per-connection timeout for the build and clean-stage.sh
# restores the pristine file; the restore is an `if [ -f ]` that skips silently
# when the saved copy is gone. The base ships no timeout= line at all.
if grep -qE '^[[:space:]]*timeout[[:space:]]*=' /etc/dnf/dnf.conf; then
    echo "FAIL: /etc/dnf/dnf.conf still carries the build-time timeout (clean-stage.sh restore skipped?)"
    exit 1
fi
# flatpak-add-fedora-repos.service is masked AND removed (clean-stage.sh): the
# unit file must be gone from /usr/lib and the mask link must point at /dev/null.
FAFR=flatpak-add-fedora-repos.service
if [ -e "/usr/lib/systemd/system/$FAFR" ]; then
    echo "FAIL: /usr/lib/systemd/system/$FAFR still shipped (clean-stage.sh rm skipped?)"
    exit 1
fi
if [ "$(readlink "/etc/systemd/system/$FAFR" 2>/dev/null)" != "/dev/null" ]; then
    echo "FAIL: $FAFR is not masked (/etc/systemd/system/$FAFR -> /dev/null expected)"
    exit 1
fi

# --- Phase 22: the rpmdb the build rewrites (build.sh step 4) ---
# Every rpm -q above answers from the pages it happens to read: a partially
# corrupted rpmdb (kernel 6.17-azure overlay writeback loss on runner image
# 20260816+, shipped as release 44.20260823) passes them all and breaks
# rpm/dnf on the deployed host. A full PRAGMA integrity_check walks every btree
# page, and the absent WAL/SHM sidecars prove the rewrite ran. libdnf5's
# transaction history was the second database of the same shape until
# clean-stage.sh started deleting that directory outright. NOTE: in-build reads
# are warm page cache and can pass on torn on-disk bytes — the post-rechunk
# check-image-integrity.sh in reusable-build.yml is the one that reads cold.
python3 - <<'PYEOF'
import os, sqlite3, sys
DATABASES = {
    '/usr/share/rpm/rpmdb.sqlite': ('Packages', 2000),
}
for path, (table, minimum) in DATABASES.items():
    for sidecar in (path + '-wal', path + '-shm'):
        if os.path.exists(sidecar):
            print(f'FAIL: {sidecar} present — build.sh step 4 did not run')
            sys.exit(1)
    # heavy corruption makes sqlite RAISE instead of returning findings rows
    try:
        db = sqlite3.connect(f'file:{path}?mode=ro&immutable=1', uri=True)
        rows = db.execute('PRAGMA integrity_check').fetchall()
        if rows != [('ok',)]:
            print(f'FAIL: {path} integrity_check reports corruption:', str(rows)[:300])
            sys.exit(1)
        count = db.execute(f'SELECT count(*) FROM {table}').fetchone()[0]
    except sqlite3.Error as exc:
        print(f'FAIL: {path} unreadable: {exc}')
        sys.exit(1)
    if count < minimum:
        print(f'FAIL: {path} implausibly small ({count} rows in {table})')
        sys.exit(1)
    print(f'{path} integrity ok ({count} rows in {table})')
PYEOF

echo "MX smoke tests OK."
echo "::endgroup::"
