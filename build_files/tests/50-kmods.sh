#!/usr/bin/env bash
# Smoke test of 50-kmods.sh: the staged modules under updates/, stamped for
# the image's one kernel and preferred by modprobe, the base's own modules
# still resolving after the build's depmod, then the MControlCenter installer
# exercised on a fixture root against synthetic tarballs. A build has no MSI
# hardware and no system bus, so loading the modules is a host proof.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines. The test
# itself stops when kernel_version finds two kernels or none, or when
# build_files/kmods holds no source.env to read.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
# shellcheck source=../lib/log.sh
source "$CTX/build_files/lib/log.sh"
# shellcheck source=../lib/kmod.sh
source "$CTX/build_files/lib/kmod.sh"

DEP_SNAPSHOT=$BUILD_STATE/modules.base.dep.gz
# The recorded lines of the base's in-tree modules our updates/ builds displace
# on purpose: msi-ec, and ntfs where the kernel builds fs/ntfs.
DISPLACED_ON_PURPOSE='kernel/drivers/platform/x86/msi-ec.ko:
kernel/fs/ntfs/ntfs.ko:'
HELPER=/usr/libexec/bazzite-mx-msi-setup
TARBALL_TOP=MControlCenter-9.9-bin

# --- the kernel and the modules -----------------------------------------------

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

# check_staged_module <kernel> <name> [<version>]: the module under updates/
# is readable, built for the kernel, the one modprobe picks, carries BTF, and
# at source.env's version when one is pinned.
check_staged_module() {
    local kernel=$1
    local name=$2
    local pinned_version=${3:-}
    local module=/usr/lib/modules/$kernel/updates/$name.ko
    local vermagic resolved built_version sections

    if [ -f "$module" ] && modinfo "$module" > /dev/null 2>&1; then
        echo "OK: $module is a readable module ($(stat -c %s "$module") bytes)"
    else
        echo "FAIL: $module missing or not a module"
        return 0
    fi

    vermagic=$(modinfo -F vermagic "$module" 2>&1 || true)

    if [[ $vermagic == "$kernel "* ]]; then
        echo "OK: $name vermagic names $kernel"
    else
        echo "FAIL: $name vermagic '${vermagic:-empty}' does not name $kernel"
    fi

    resolved=$(module_resolved_by_modprobe "$kernel" "$name" || true)

    if [ -n "$resolved" ] && [ "$(realpath "$resolved")" = "$(realpath "$module")" ]; then
        echo "OK: modprobe $name resolves to updates/ ($resolved)"
    else
        echo "FAIL: modprobe $name resolves to '$resolved'"
    fi

    sections=$(readelf -S "$module" 2>&1 || true)

    if grep -q ' \.BTF ' <<< "$sections"; then
        echo "OK: $name carries BTF"
    else
        echo "FAIL: $name carries no .BTF section"
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

# Each staged module's name and version come from its source.env.
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

# The build re-ran depmod over the base's modules too. Every dependency line
# 00-prep.sh recorded before that run must still be there, byte for byte: a
# base module gone and a base dependency gone both read as a recorded line the
# tree no longer has. depmod keeps one entry per module name and searches
# updates/ first, so an in-tree module sharing a name with ours loses its line:
# only the paths in DISPLACED_ON_PURPOSE are exempt, so a new one reads red.
# The subject is the record, never a list read from the tree.
check_base_modules_survive_depmod() {
    local kernel=$1
    local current=/usr/lib/modules/$kernel/modules.dep
    local recorded lost

    recorded=$(gzip -dc "$DEP_SNAPSHOT" 2> /dev/null || true)

    if [ -z "$recorded" ] || [ ! -s "$current" ]; then
        echo "FAIL: $DEP_SNAPSHOT or $current missing or empty"
        return 0
    fi

    lost=$(grep -Fxv -f "$current" <<< "$recorded" || true)
    lost=$(grep -Fxv "$DISPLACED_ON_PURPOSE" <<< "$lost" || true)

    if [ -z "$lost" ]; then
        echo "OK: the base's $(grep -c '' <<< "$recorded") module lines survive depmod," \
            "bar the ones displaced on purpose"
    else
        echo "FAIL: base modules gone from modules.dep:" \
            "$(cut -d: -f1 <<< "$lost" | head -n3 | on_one_line none)"
    fi
}

check_msi_modules_stay_opt_in() {
    if [ ! -e /etc/modules-load.d/bazzite-mx-msi.conf ] \
        && ! grep -rqsE 'msi[-_]ec|acpi_ec' /usr/lib/modules-load.d/; then
        echo "OK: nothing loads the modules at boot (opt-in through ujust setup-msi)"
    else
        echo "FAIL: a modules-load file names msi-ec or acpi_ec in the image"
    fi
}

# --- the MControlCenter installer on a fixture --------------------------------

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
            "$(tail -n2 "$work/install.out" | on_one_line 'no output')"
    fi

    if [ -x "$fixture/usr/local/bin/mcontrolcenter" ] \
        && [ -x "$fixture/usr/local/bin/mcontrolcenter-helper" ] \
        && [ -f "$fixture/usr/local/share/applications/mcontrolcenter.desktop" ] \
        && [ -f "$fixture/usr/local/share/icons/hicolor/scalable/apps/mcontrolcenter.svg" ] \
        && [ -f "$fixture/etc/dbus-1/system.d/mcontrolcenter-helper.conf" ]; then
        echo "OK: GUI and helper in /usr/local/bin, desktop file, icon and D-Bus policy in place"
    else
        installed_files=$(find "$fixture" -type f 2> /dev/null | sed "s|$fixture||" | tr '\n' ' ' \
            || true)
        echo "FAIL: installed layout: ${installed_files:-no file under the fixture}"
    fi

    if grep -qx 'Exec=/usr/local/bin/mcontrolcenter-helper' "$service" 2> /dev/null \
        && grep -qx 'User=root' "$service" 2> /dev/null \
        && grep -qx 'Name=mcontrolcenter.helper' "$service" 2> /dev/null; then
        echo "OK: activation file points at /usr/local/bin/mcontrolcenter-helper, User=root kept"
    else
        echo "FAIL: activation file: $(cat "$service" 2>&1 | on_one_line 'empty')"
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

    status_out=$(ROOT=$fixture "$HELPER" status 2>&1 || true)

    if grep -q '^MControlCenter: 9.9 under' <<< "$status_out"; then
        echo "OK: status reports the installed version on the fixture"
    else
        echo "FAIL: status:" \
            "$(grep MControlCenter <<< "$status_out" | on_one_line 'no MControlCenter line')"
    fi

    if ROOT=$fixture "$HELPER" remove > /dev/null 2>&1 \
        && [ -z "$(find "$fixture" -type f 2> /dev/null)" ]; then
        echo "OK: remove takes every installed file back out"
    else
        files_left=$(find "$fixture" -type f 2> /dev/null | sed "s|$fixture||" | tr '\n' ' ' \
            || true)
        echo "FAIL: after remove: ${files_left:-no file left, remove exited non-zero}"
    fi

    rm -rf "$fixture"
}

# install_refused <work> <tarball name>: status 0 when the installer exits
# non-zero on $work/<name>.tar.gz and leaves no fixture root behind; its
# output lands in $work/<name>.out. The root an earlier accepted case left
# goes first, so each case is judged on its own install.
install_refused() {
    local work=$1
    local name=$2
    local fixture=$work/root

    rm -rf "$fixture"

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
        && grep -q "unexpected top directory '$other_top'" "$work/src.out" 2> /dev/null; then
        echo "OK: installer refuses a top directory that is not MControlCenter-<version>-bin"
    else
        echo "FAIL: a source-layout tarball was accepted (or left files):" \
            "$(tail -n1 "$work/src.out" | on_one_line 'no output')"
    fi

    fixture_write_activation "$work" mcontrolcenter.helper
    fixture_pack "$work" no-exec "$TARBALL_TOP"

    if install_refused "$work" no-exec \
        && grep -q 'Exec line not rewritten' "$work/no-exec.out" 2> /dev/null; then
        echo "OK: installer refuses an activation file without an Exec line, installs nothing"
    else
        echo "FAIL: an activation file without Exec was accepted (or left files):" \
            "$(tail -n1 "$work/no-exec.out" | on_one_line 'no output')"
    fi

    fixture_write_activation "$work" org.example.helper /usr/libexec/mcontrolcenter-helper
    fixture_pack "$work" other-name "$TARBALL_TOP"

    if install_refused "$work" other-name \
        && grep -q 'Name is not mcontrolcenter.helper' "$work/other-name.out" 2> /dev/null; then
        echo "OK: installer refuses an activation file with another bus name, installs nothing"
    else
        echo "FAIL: an activation file with another bus name was accepted (or left files):" \
            "$(tail -n1 "$work/other-name.out" | on_one_line 'no output')"
    fi
}

# Known-bad: a file that is not a gzip tarball put gzip's and tar's lines
# around the helper's ERROR.
check_install_refuses_a_non_gzip_tarball() {
    local work=$1

    printf 'not a tarball\n' > "$work/garbage.tar.gz"

    if install_refused "$work" garbage \
        && grep -q 'is not a gzip tarball' "$work/garbage.out" 2> /dev/null \
        && ! grep -qE '^(gzip|tar):' "$work/garbage.out" 2> /dev/null; then
        echo "OK: installer refuses a non-gzip tarball with one ERROR line"
    else
        echo "FAIL: a non-gzip tarball: $(on_one_line 'no output' < "$work/garbage.out")"
    fi
}

# The answers of the GitHub API `latest` reads, with curl stubbed on PATH.
# Known-bad: an answer that is not JSON, and one without assets, left jq's own
# line as the only output and exited 5, outside the header's `ERROR:` + exit 1.
check_latest_refuses_bad_answers() {
    local work=$1
    local body=$2
    local what=$3
    local pattern=$4
    local output status

    mkdir -p "$work/bin"
    printf '#!/usr/bin/env bash\ncat << "BODY"\n%s\nBODY\n' "$body" > "$work/bin/curl"
    chmod 755 "$work/bin/curl"

    if output=$(PATH=$work/bin:$PATH "$HELPER" latest 2>&1); then
        status=0
    else
        status=$?
    fi

    rm -f "$work/bin/curl"

    if [ "$status" -eq 1 ] && [ "$(grep -c '' <<< "$output")" -eq 1 ] \
        && grep -q "$pattern" <<< "$output"; then
        echo "OK: latest refuses $what with one ERROR line, exit 1"
    else
        echo "FAIL: latest on $what (exit $status):" \
            "$(on_one_line 'no output' <<< "$output")"
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
        echo "FAIL: status exit $status_rc: $(head -n2 <<< "$status_out" | on_one_line 'no output')"
    fi

    # Known-bad: an empty vendor file printed `system vendor:  (…`.
    : > "$work/vendor"
    status_out=$(DMI_VENDOR_FILE=$work/vendor "$HELPER" status 2>&1 || true)

    if grep -q '^system vendor: unknown ' <<< "$status_out"; then
        echo "OK: status says unknown for an empty vendor file"
    else
        echo "FAIL: status on an empty vendor file:" \
            "$(grep '^system vendor' <<< "$status_out" | on_one_line 'no vendor line')"
    fi

    printf 'Acme Computers\n' > "$work/vendor"

    if ! DMI_VENDOR_FILE=$work/vendor "$HELPER" enable > "$work/enable.out" 2>&1 \
        && grep -q 'not an MSI system (Acme Computers)' "$work/enable.out" 2> /dev/null; then
        echo "OK: enable refuses a non-MSI system (DMI gate on a fixture vendor)"
    else
        echo "FAIL: enable on a non-MSI build:" \
            "$(head -n1 "$work/enable.out" 2>&1 | on_one_line 'no output')"
    fi

    # Known-bad: a module the kernel refused (Secure Boot on) went on to
    # install MControlCenter; a modprobe stub refuses it the same way.
    printf 'Micro-Star International Co., Ltd.\n' > "$work/vendor"
    mkdir -p "$work/bin" "$work/msi-root/etc/modules-load.d"
    printf '#!/usr/bin/env bash\necho "modprobe: Key was rejected by service" >&2\nexit 1\n' \
        > "$work/bin/modprobe"
    chmod 755 "$work/bin/modprobe"

    if ! PATH=$work/bin:$PATH ROOT=$work/msi-root DMI_VENDOR_FILE=$work/vendor "$HELPER" enable \
        > "$work/enable.out" 2>&1 \
        && grep -q '^ERROR: modprobe msi-ec failed' "$work/enable.out" \
        && ! grep -q 'modules loaded now' "$work/enable.out"; then
        echo "OK: enable stops on a module the kernel refuses"
    else
        echo "FAIL: enable with msi-ec refused: $(on_one_line 'no output' < "$work/enable.out")"
    fi

    rm -f "$work/bin/modprobe"
}

# --- main ---------------------------------------------------------------------

kernel=$(kernel_version)

check_every_staged_module "$kernel"
check_base_modules_survive_depmod "$kernel"
check_msi_modules_stay_opt_in

work=$(mktemp -d)
fixture_write_app "$work"
fixture_pack "$work" good "$TARBALL_TOP"
check_install_from_release_layout "$work"
check_status_and_remove_on_fixture "$work"
check_latest_refuses_bad_answers "$work" '<html>not json</html>' \
    'an answer that is not JSON' '^ERROR: GitHub API: .* is not JSON: '
check_latest_refuses_bad_answers "$work" '{"tag_name": "v1.2.3"}' \
    'a release without assets' '^ERROR: release v1.2.3 carries no MControlCenter'
check_install_refuses_bad_tarballs "$work"
check_install_refuses_a_non_gzip_tarball "$work"
check_status_and_enable_in_the_build "$work"
rm -rf "$work"
