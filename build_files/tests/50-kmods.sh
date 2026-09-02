#!/usr/bin/env bash
# Kernel modules for the MSI laptop: msi-ec and acpi_ec under updates/ for the
# image's one kernel, stamped for it, resolved by modprobe ahead of the
# in-tree msi-ec, listed by depmod, not loaded at boot by the image; the
# MControlCenter installer behind `ujust setup-msi` proven on a fixture with
# a synthetic tarball, positive and known-bad; the recipe defined and runnable.
# Loading the modules and MControlCenter's D-Bus helper are proven on the MSI
# host in phase 4 (no hardware, no system bus in a build).
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
# shellcheck source=../lib/log.sh
source "$CTX/build_files/lib/log.sh"
# shellcheck source=../lib/kmod.sh
source "$CTX/build_files/lib/kmod.sh"

HELPER=/usr/libexec/bazzite-mx-msi-setup
RECIPES=/usr/share/ublue-os/just/95-bazzite-mx.just
TARBALL_TOP=MControlCenter-9.9-bin

# --- the kernel and the modules -----------------------------------------------

# kernel_version ends the build through fail_build, so the two trees it must
# refuse are probed in subshells: their exit must not end the test.
check_kernel_version_guard() {
    local guard

    guard=$(mktemp -d)
    mkdir -p "$guard/none" "$guard/two/a" "$guard/two/b"

    if ! (kernel_version "$guard/none") > /dev/null 2>&1 \
        && ! (kernel_version "$guard/two") > /dev/null 2>&1; then
        echo "OK: kernel_version refuses an empty tree and a two-kernel tree"
    else
        echo "FAIL: kernel_version accepted an empty or a two-kernel tree"
    fi

    rm -rf "$guard"
}

# The path modprobe would insmod for <module>, empty when it refuses the
# name: the refusal stays out of the pipeline's status, the form 50-kmods.sh
# uses too.
module_resolved_by_modprobe() {
    local kernel=$1
    local module=$2

    { modprobe -S "$kernel" -n --show-depends "$module" 2>&1 || true; } \
        | awk '$1 == "insmod" { print $2 }' \
        | tail -n1
}

check_unknown_module_resolves_to_nothing() {
    local kernel=$1
    local resolved

    resolved=$(module_resolved_by_modprobe "$kernel" bazzite-mx-no-such-module)
    if [ -z "$resolved" ]; then
        echo "OK: an unknown module resolves to nothing without ending the test"
    else
        echo "FAIL: an unknown module resolved to '$resolved'"
    fi
}

# check_staged_module <kernel> <name> [<version>]: the module under updates/
# is readable, built for the kernel, the one modprobe picks, indexed,
# unsigned, and at source.env's version when one is pinned.
check_staged_module() {
    local kernel=$1
    local name=$2
    local pinned_version=${3:-}
    local module=/usr/lib/modules/$kernel/updates/$name.ko
    local vermagic resolved built_version signature

    if [ -f "$module" ] && modinfo "$module" > /dev/null 2>&1; then
        echo "OK: $module is a readable module ($(stat -c %s "$module") bytes)"
    else
        echo "FAIL: $module missing or not a module"
        return 0
    fi

    vermagic=$(modinfo -F vermagic "$module")
    if [[ $vermagic == "$kernel "* ]]; then
        echo "OK: $name vermagic names $kernel"
    else
        echo "FAIL: $name vermagic '$vermagic' does not name $kernel"
    fi

    resolved=$(module_resolved_by_modprobe "$kernel" "$name")
    if [ -n "$resolved" ] && [ "$(realpath "$resolved")" = "$(realpath "$module")" ]; then
        echo "OK: modprobe $name resolves to updates/ ($resolved)"
    else
        echo "FAIL: modprobe $name resolves to '$resolved'"
    fi

    if grep -q "^updates/$name.ko:" "/usr/lib/modules/$kernel/modules.dep"; then
        echo "OK: updates/$name.ko in modules.dep"
    else
        echo "FAIL: updates/$name.ko not in modules.dep"
    fi

    signature=$(modinfo -F sig_id "$module" 2> /dev/null || true)
    if [ -n "$signature" ]; then
        echo "FAIL: $name carries a signature"
    else
        echo "OK: $name unsigned"
    fi

    if [ -z "$pinned_version" ]; then
        return 0
    fi

    built_version=$(modinfo -F version "$module" 2>&1 || true)
    if [ "$built_version" = "$pinned_version" ]; then
        echo "OK: $name version $pinned_version (source.env's, not the in-tree copy's)"
    else
        echo "FAIL: $name version '$built_version', source.env says $pinned_version"
    fi
}

# source.env is the only place a module name or version is written down.
check_every_staged_module() {
    local kernel=$1
    local source_env

    for source_env in "$CTX"/build_files/kmods/*/source.env; do
        unset KO_NAME KO_VERSION
        # shellcheck disable=SC1090
        source "$source_env"

        check_staged_module "$kernel" "$KO_NAME" "${KO_VERSION:-}"
    done
}

check_msi_modules_stay_opt_in() {
    local kernel=$1
    local in_tree_msi_ec=/usr/lib/modules/$kernel/kernel/drivers/platform/x86/msi-ec.ko

    if [ -f "$in_tree_msi_ec" ]; then
        echo "OK: the base's in-tree msi-ec is still in place (updates/ wins by depmod order)"
    else
        echo "FAIL: the base's in-tree msi-ec.ko is gone"
    fi

    if [ ! -e /etc/modules-load.d/bazzite-mx-msi.conf ] \
        && ! grep -rqs 'msi-ec\|acpi_ec' /usr/lib/modules-load.d/; then
        echo "OK: nothing loads the modules at boot (opt-in through ujust setup-msi)"
    else
        echo "FAIL: a modules-load file names msi-ec or acpi_ec in the image"
    fi
}

# --- the MControlCenter installer on a fixture --------------------------------

check_helper_file() {
    if [ -x "$HELPER" ] && bash -n "$HELPER"; then
        echo "OK: $HELPER executable and parses"
    else
        echo "FAIL: $HELPER missing, not executable or does not parse"
    fi

    if [ "$(stat -c %a "$HELPER")" = "755" ]; then
        echo "OK: $HELPER mode 755"
    else
        echo "FAIL: $HELPER mode $(stat -c %a "$HELPER")"
    fi
}

# fixture_write_app <work>: the app/ directory in the shape upstream releases,
# under $TARBALL_TOP; the activation file is the one upstream ships.
fixture_write_app() {
    local work=$1
    local app=$work/$TARBALL_TOP/app

    mkdir -p "$app"
    printf '#!/bin/sh\necho gui\n' > "$app/mcontrolcenter"
    printf '#!/bin/sh\necho helper\n' > "$app/mcontrolcenter-helper"
    printf '<busconfig/>\n' > "$app/mcontrolcenter-helper.conf"
    fixture_write_activation "$work" mcontrolcenter.helper /usr/libexec/mcontrolcenter-helper
    printf '[Desktop Entry]\nName=MControlCenter\nExec=mcontrolcenter\nType=Application\n' \
        > "$app/mcontrolcenter.desktop"
    printf '<svg/>\n' > "$app/mcontrolcenter.svg"
}

# fixture_write_activation <work> <bus name> [<exec path>]: the D-Bus
# activation file, without its Exec line when no path is given.
fixture_write_activation() {
    local work=$1
    local bus_name=$2
    local exec_path=${3:-}
    local service=$work/$TARBALL_TOP/app/mcontrolcenter.helper.service

    printf '[D-BUS Service]\nName=%s\n' "$bus_name" > "$service"
    if [ -n "$exec_path" ]; then
        printf 'Exec=%s\n' "$exec_path" >> "$service"
    fi
    printf 'User=root\n' >> "$service"
}

# fixture_pack <work> <tarball name> <top directory>
fixture_pack() {
    local work=$1
    local name=$2
    local top=$3

    tar czf "$work/$name.tar.gz" -C "$work" "$top"
}

check_install_from_release_layout() {
    local work=$1
    local fixture=$work/root
    local service=$fixture/usr/local/share/dbus-1/system-services/mcontrolcenter.helper.service
    local installed_files version_recorded

    if ROOT=$fixture "$HELPER" install "$work/good.tar.gz" > "$work/install.out" 2>&1; then
        echo "OK: installer accepts the release layout ($(tail -n1 "$work/install.out"))"
    else
        echo "FAIL: installer refused the good tarball:" \
            "$(tail -n2 "$work/install.out" | tr '\n' ' ')"
    fi

    if [ -x "$fixture/usr/local/bin/mcontrolcenter" ] \
        && [ -x "$fixture/usr/local/bin/mcontrolcenter-helper" ] \
        && [ -f "$fixture/usr/local/share/applications/mcontrolcenter.desktop" ] \
        && [ -f "$fixture/usr/local/share/icons/hicolor/scalable/apps/mcontrolcenter.svg" ] \
        && [ -f "$fixture/etc/dbus-1/system.d/mcontrolcenter-helper.conf" ]; then
        echo "OK: GUI and helper in /usr/local/bin, desktop file, icon and D-Bus policy in place"
    else
        installed_files=$(find "$fixture" -type f | sed "s|$fixture||" | tr '\n' ' ')
        echo "FAIL: installed layout: $installed_files"
    fi

    if grep -qx 'Exec=/usr/local/bin/mcontrolcenter-helper' "$service" 2> /dev/null \
        && grep -qx 'User=root' "$service" && grep -qx 'Name=mcontrolcenter.helper' "$service"; then
        echo "OK: activation file points at /usr/local/bin/mcontrolcenter-helper, User=root kept"
    else
        echo "FAIL: activation file: $(cat "$service" 2>&1 | tr '\n' ' ')"
    fi

    version_recorded=$(cat "$fixture/usr/local/share/mcontrolcenter/version" 2>&1 || true)
    if [ "$version_recorded" = "9.9" ]; then
        echo "OK: version recorded from the tarball name (9.9)"
    else
        echo "FAIL: version file: '$version_recorded'"
    fi
}

check_status_and_remove_on_fixture() {
    local work=$1
    local fixture=$work/root
    local status_out files_left

    # Output captured first, against the SIGPIPE in docs/gotchas.md.
    status_out=$(ROOT=$fixture "$HELPER" status 2>&1 || true)
    if grep -q '^MControlCenter: 9.9 under' <<< "$status_out"; then
        echo "OK: status reports the installed version on the fixture"
    else
        echo "FAIL: status: $(grep MControlCenter <<< "$status_out")"
    fi

    if ROOT=$fixture "$HELPER" remove > /dev/null 2>&1 && [ -z "$(find "$fixture" -type f)" ]; then
        echo "OK: remove takes every installed file back out"
    else
        files_left=$(find "$fixture" -type f | sed "s|$fixture||" | tr '\n' ' ')
        echo "FAIL: after remove: $files_left"
    fi

    rm -rf "$fixture"
}

# install_refused <work> <tarball name>: status 0 when the installer exits
# non-zero on $work/<name>.tar.gz and leaves no fixture root behind; its
# output lands in $work/<name>.out.
install_refused() {
    local work=$1
    local name=$2
    local fixture=$work/root

    if ROOT=$fixture "$HELPER" install "$work/$name.tar.gz" > "$work/$name.out" 2>&1; then
        return 1
    fi

    if [ -e "$fixture" ]; then
        return 1
    fi

    return 0
}

# Known-bad tarballs: each is refused before the first file lands.
check_install_refuses_bad_tarballs() {
    local work=$1
    local other_top=MControlCenter-9.9-src

    rm -f "$work/$TARBALL_TOP/app/mcontrolcenter-helper"
    fixture_pack "$work" no-helper "$TARBALL_TOP"
    if install_refused "$work" no-helper; then
        echo "OK: installer refuses a tarball without the helper, installs nothing"
    else
        echo "FAIL: a tarball without the helper was accepted (or left files)"
    fi

    mkdir -p "$work/other/app"
    fixture_pack "$work" other other
    if install_refused "$work" other; then
        echo "OK: installer refuses a tarball with another top directory"
    else
        echo "FAIL: a foreign tarball was accepted"
    fi

    printf '#!/bin/sh\necho helper\n' > "$work/$TARBALL_TOP/app/mcontrolcenter-helper"
    mkdir -p "$work/$other_top"
    cp -a "$work/$TARBALL_TOP/app" "$work/$other_top/"
    fixture_pack "$work" src "$other_top"
    if install_refused "$work" src \
        && grep -q "unexpected top directory '$other_top'" "$work/src.out"; then
        echo "OK: installer refuses a top directory that is not MControlCenter-<version>-bin"
    else
        echo "FAIL: a source-layout tarball was accepted (or left files):" \
            "$(tail -n1 "$work/src.out")"
    fi

    fixture_write_activation "$work" mcontrolcenter.helper
    fixture_pack "$work" no-exec "$TARBALL_TOP"
    if install_refused "$work" no-exec \
        && grep -q 'Exec line not rewritten' "$work/no-exec.out"; then
        echo "OK: installer refuses an activation file without an Exec line, installs nothing"
    else
        echo "FAIL: an activation file without Exec was accepted (or left files):" \
            "$(tail -n1 "$work/no-exec.out")"
    fi

    fixture_write_activation "$work" org.example.helper /usr/libexec/mcontrolcenter-helper
    fixture_pack "$work" other-name "$TARBALL_TOP"
    if install_refused "$work" other-name \
        && grep -q 'Name is not mcontrolcenter.helper' "$work/other-name.out"; then
        echo "OK: installer refuses an activation file with another bus name, installs nothing"
    else
        echo "FAIL: an activation file with another bus name was accepted (or left files):" \
            "$(tail -n1 "$work/other-name.out")"
    fi
}

check_status_and_enable_in_the_build() {
    local work=$1
    local status_out status_rc

    if status_out=$("$HELPER" status 2>&1); then
        status_rc=0
    else
        status_rc=$?
    fi

    if [ "$status_rc" -eq 0 ] && grep -q '^system vendor: ' <<< "$status_out"; then
        echo "OK: status runs in the build (exit 0, $(wc -l <<< "$status_out") lines)"
    else
        echo "FAIL: status exit $status_rc: $(head -n2 <<< "$status_out" | tr '\n' ' ')"
    fi

    printf 'Acme Computers\n' > "$work/vendor"
    if ! DMI_VENDOR_FILE=$work/vendor "$HELPER" enable > "$work/enable.out" 2>&1 \
        && grep -q 'not an MSI system (Acme Computers)' "$work/enable.out"; then
        echo "OK: enable refuses a non-MSI system (DMI gate on a fixture vendor)"
    else
        echo "FAIL: enable on a non-MSI build: $(head -n1 "$work/enable.out")"
    fi
}

# --- the recipe ---------------------------------------------------------------

check_recipe() {
    local help_out

    if has_recipe "$RECIPES" setup-msi; then
        echo "OK: recipe file defines setup-msi"
    else
        echo "FAIL: recipe summary: $(just --justfile "$RECIPES" --summary 2>&1)"
    fi

    help_out=$(just --justfile "$RECIPES" setup-msi help 2>&1 || true)
    if grep -q '^Usage: ujust setup-msi' <<< "$help_out"; then
        echo "OK: setup-msi help runs"
    else
        echo "FAIL: setup-msi help: $(head -n3 <<< "$help_out")"
    fi
}

# --- main ---------------------------------------------------------------------

kernel=$(kernel_version)
echo "OK: one kernel in the image ($kernel)"

check_kernel_version_guard
check_unknown_module_resolves_to_nothing "$kernel"
check_every_staged_module "$kernel"
check_msi_modules_stay_opt_in "$kernel"

check_helper_file
work=$(mktemp -d)
fixture_write_app "$work"
fixture_pack "$work" good "$TARBALL_TOP"
check_install_from_release_layout "$work"
check_status_and_remove_on_fixture "$work"
check_install_refuses_bad_tarballs "$work"
check_status_and_enable_in_the_build "$work"
rm -rf "$work"

check_recipe
