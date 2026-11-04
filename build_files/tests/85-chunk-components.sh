#!/usr/bin/env bash
# Smoke test of 85-chunk-components.sh: every file of system_files/ as
# installed, and every file a build script writes outside an RPM, carries a
# `bazzite-mx-*` component and an update interval when no package owns it,
# and no component when one does; a base file a build script rewrites keeps
# the base's. The subjects come from system_files/ and the lists below, never
# from the script's own table, so a file added to either without a row turns
# this red.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

BUILD_FILES=$(realpath "$(dirname "$(realpath "$0")")/..")
SYSTEM_FILES=$(realpath "$BUILD_FILES/../system_files")

# Written by build scripts, not copied from system_files/; the modprobe file
# of 55-ntfsplus.sh exists on one kernel only and is covered by its pattern.
BUILD_WRITTEN=(
    /etc/pki/containers/matrixdj96.pub
    /usr/bin/shfmt
    /usr/lib/bazzite-mx/build-state
    /usr/lib/modprobe.d/bazzite-mx-*.conf
    /usr/lib/modules/*/updates/*.ko
    /usr/lib/opt/1Password
    /usr/lib/tmpfiles.d/bazzite-mx-opt.conf
    /usr/lib64/firefox/browser/defaults/preferences/01-bazzite-global.js
    /usr/share/ublue-os/image-info.json
)

# Owned by a package, tagged by the base, rewritten by a build script that
# must keep the base's component.
BASE_TAGGED=(
    /etc/dnf/dnf.conf
    /etc/xdg/kcm-about-distrorc
)

check_component() {
    local path=$1
    local component interval

    component=$(getfattr --only-values -n user.component "$path" 2> /dev/null || true)
    interval=$(getfattr --only-values -n user.update-interval "$path" 2> /dev/null || true)

    if rpm -qf "$path" > /dev/null 2>&1; then
        if [ -z "$component" ]; then
            echo "OK: $path owned by a package, no component"
        else
            echo "FAIL: $path owned by a package yet tagged $component"
        fi
    elif [[ "$component" == bazzite-mx-* ]] && [ -n "$interval" ]; then
        echo "OK: $path in $component ($interval)"
    else
        echo "FAIL: $path unowned, tagged '${component:-none}' '${interval:-none}'"
    fi
}

check_system_files() {
    local file

    while IFS= read -r file; do
        check_component "${file#"$SYSTEM_FILES"}"
    done < <(find "$SYSTEM_FILES" -type f | sort)
}

check_build_written() {
    local pattern path matches

    for pattern in "${BUILD_WRITTEN[@]}"; do
        matches=$(compgen -G "$pattern" || true)

        if [ -z "$matches" ]; then
            echo "FAIL: $pattern matches nothing"
            continue
        fi

        while IFS= read -r path; do
            check_component "$path"
        done <<< "$matches"
    done
}

check_base_tags() {
    local path component interval

    for path in "${BASE_TAGGED[@]}"; do
        component=$(getfattr --only-values -n user.component "$path" 2> /dev/null || true)
        interval=$(getfattr --only-values -n user.update-interval "$path" 2> /dev/null || true)

        if [ -n "$component" ] && [[ "$component" != bazzite-mx-* ]] && [ -n "$interval" ]; then
            echo "OK: $path keeps the base's $component ($interval)"
        else
            echo "FAIL: $path lost the base's component: '${component:-none}' '${interval:-none}'"
        fi
    done
}

check_self_test chunk-components bash "$BUILD_FILES/85-chunk-components.sh"
check_system_files
check_build_written
check_base_tags
