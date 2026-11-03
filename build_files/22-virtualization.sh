#!/usr/bin/env bash
# Virtualization: libvirt as modular daemons, QEMU/KVM, virt-manager and
# quickemu, from an explicit package list; the base's dnf.conf keeps weak
# dependencies off, so the binfmt packages stay out.
#
# Usage: run by build.sh; no arguments.
# Writes: the packages; ublue-os-libvirt-workarounds.service enabled; the
#   base's bazzite-libvirtd-setup.service removed; the virt-manager
#   Flatpak denied in the base's Flatpak filter; the Portal's virtualization
#   group removed, its virt-on and virt-off being Bazzite's options.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

LIBVIRTD_SETUP=/usr/lib/systemd/system/bazzite-libvirtd-setup.service

# --- helpers ------------------------------------------------------------------

# Every installed mesa-* package but mesa-demos, sorted; none is an empty
# list, not an error. Status 1 when rpm cannot read the database, or the
# comparison would find no change on two lists it never read.
installed_mesa_packages() {
    local installed

    if ! installed=$(rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 'mesa-*'); then
        return 1
    fi

    grep -v '^mesa-demos-' <<< "$installed" | sort -u || true
}

# --- the steps ----------------------------------------------------------------

# quickemu needs glxinfo, from mesa-demos. The base excludes `mesa-*` from
# the `fedora` repository because Mesa comes from Terra, and that glob catches
# mesa-demos too: the exclude is lifted for this one package and the build
# proves no other mesa-* package moved.
install_mesa_demos() {
    local before after changed

    if ! before=$(installed_mesa_packages); then
        fail_build "cannot read the installed mesa packages before the install"
    fi

    dnf_retry -y --setopt=fedora.exclude= install mesa-demos

    if ! after=$(installed_mesa_packages); then
        fail_build "cannot read the installed mesa packages after the install"
    fi

    if [ "$before" != "$after" ]; then
        changed=$(diff <(echo "$before") <(echo "$after") || true)
        fail_build "installing mesa-demos changed other mesa packages: $changed"
    fi
}

install_virtualization_packages() {
    dnf_retry -y install \
        guestfs-tools \
        libvirt \
        libvirt-daemon-kvm \
        libvirt-nss \
        qemu-kvm \
        quickemu \
        swtpm \
        swtpm-tools \
        virt-install \
        virt-manager \
        virt-viewer \
        waypipe

    install_from_repo copr:copr.fedorainfracloud.org:ublue-os:packages ublue-os-libvirt-workarounds

    # The virt-manager Flatpak would be a twin of the RPM.
    deny_flatpak 'org.virt_manager.virt-manager/*'
}

# Bazzite's `virt-on`, run on a host before it came to the image, leaves the
# base's setup unit enabled, and here it would enable libvirtd at the next boot:
# no package owns the unit and nothing of the image calls it, so it goes.
set_up_libvirt_units() {
    systemctl enable ublue-os-libvirt-workarounds.service
    rm -f "$LIBVIRTD_SETUP"
}

# --- main ---------------------------------------------------------------------

install_mesa_demos
install_virtualization_packages
set_up_libvirt_units
remove_portal_group virtualization

libvirt_version=$(rpm -q --qf '%{VERSION}' libvirt)
qemu_version=$(rpm -q --qf '%{VERSION}' qemu-kvm)
quickemu_version=$(rpm -q --qf '%{VERSION}' quickemu)
log "virtualization: libvirt $libvirt_version, qemu-kvm $qemu_version," \
    "quickemu $quickemu_version"
