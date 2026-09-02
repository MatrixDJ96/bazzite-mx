#!/usr/bin/env bash
# Smoke test of 41-sunshine.sh: Sunshine from the vendored COPR. The key, the
# KMS capabilities, the udev and modules-load files, the disabled user unit,
# the base's helpers and announcement, and the recipe that replaces Bazzite's.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
# shellcheck source=../lib/gpg.sh
source "$CTX/build_files/lib/gpg.sh"

KEY=/etc/pki/rpm-gpg/RPM-GPG-KEY-copr-lizardbyte-stable
SUNSHINE_REPO=/etc/yum.repos.d/sunshine.repo
UNIT=app-dev.lizardbyte.app.Sunshine.service
UNIT_FILE=/usr/lib/systemd/user/$UNIT
UDEV_RULES=/usr/lib/udev/rules.d/60-sunshine.rules
MODULES_LOAD=/usr/lib/modules-load.d/60-sunshine.conf
APPS_JSON=/usr/share/sunshine/apps.json
ANNOUNCEMENT=/usr/share/ublue-os/announcements/sunshine-brew.msg.json
RECIPE=/usr/share/ublue-os/just/82-bazzite-sunshine.just

# --- the package --------------------------------------------------------------

check_binary() {
    local capabilities version

    if rpm -q Sunshine > /dev/null && [ -x /usr/bin/sunshine ]; then
        echo "OK: Sunshine $(rpm -q --qf '%{VERSION}' Sunshine)"
    else
        echo "FAIL: Sunshine not installed"
    fi

    capabilities=$(getcap /usr/bin/sunshine 2>&1 || true)
    if [[ $capabilities == *cap_sys_admin* && $capabilities == *cap_sys_nice* ]]; then
        echo "OK: /usr/bin/sunshine carries the KMS capabilities ($capabilities)"
    else
        echo "FAIL: /usr/bin/sunshine capabilities: '$capabilities'"
    fi

    version=$(sunshine --version 2>&1 || true)
    if grep -qi sunshine <<< "$version"; then
        echo "OK: sunshine --version runs"
    else
        echo "FAIL: sunshine --version: $(head -n1 <<< "$version")"
    fi
}

# The shipped key is the pinned one, the .repo reads it from the file and
# stays disabled without a priority, and dnf5 imported the key into the rpm
# keyring at install.
check_copr_repo() {
    local pinned=${KEY_FPR[$KEY]}
    local actual repo_lines

    actual=$(key_fingerprint "$KEY" || true)
    if [ "$actual" = "$pinned" ]; then
        echo "OK: $KEY fingerprint $pinned"
    else
        echo "FAIL: $KEY fingerprint $actual"
    fi

    if grep -q "^gpgkey=file://$KEY$" "$SUNSHINE_REPO" && grep -qx 'enabled=0' "$SUNSHINE_REPO" \
        && ! grep -q '^priority=' "$SUNSHINE_REPO"; then
        echo "OK: $SUNSHINE_REPO reads the vendored key, disabled, no priority"
    else
        repo_lines=$(grep -E '^(enabled|gpgkey|priority)=' "$SUNSHINE_REPO" 2>&1 | tr '\n' ' ')
        echo "FAIL: $SUNSHINE_REPO: $repo_lines"
    fi

    check_rpm_key e4f68234 "lizardbyte/stable"
}

check_user_unit() {
    local unit_lines

    check_unit_state --global "$UNIT" disabled "opt-in through the recipe"

    if grep -q '^Alias=sunshine.service$' "$UNIT_FILE" \
        && grep -q '^ExecStart=/usr/bin/sunshine$' "$UNIT_FILE"; then
        echo "OK: user unit runs /usr/bin/sunshine with the sunshine.service alias"
    else
        unit_lines=$(grep -E '^(Alias|ExecStart)=' "$UNIT_FILE" 2>&1 | tr '\n' ' ')
        echo "FAIL: user unit: $unit_lines"
    fi
}

check_device_files() {
    if grep -q 'KERNEL=="uinput".*GROUP="input"' "$UDEV_RULES" \
        && grep -qx 'uhid' "$MODULES_LOAD"; then
        echo "OK: uinput udev rule and uhid modules-load shipped"
    else
        echo "FAIL: 60-sunshine.rules or 60-sunshine.conf missing or changed"
    fi
}

check_base_files() {
    local helper

    for helper in sunshine-start-vmon sunshine-stop-vmon; do
        if [ -x "/usr/libexec/$helper" ] && bash -n "/usr/libexec/$helper"; then
            echo "OK: base helper /usr/libexec/$helper present"
        else
            echo "FAIL: /usr/libexec/$helper missing or does not parse"
        fi
    done

    check_desktop_file /usr/share/applications/dev.lizardbyte.app.Sunshine.desktop

    if [ -f "$APPS_JSON" ] && jq -e '.apps | type == "array"' "$APPS_JSON" > /dev/null 2>&1; then
        echo "OK: package apps.json parses"
    else
        echo "FAIL: $APPS_JSON missing or not the expected shape"
    fi

    if [ ! -e "$ANNOUNCEMENT" ]; then
        echo "OK: Bazzite's Sunshine Portal announcement removed"
    else
        echo "FAIL: $ANNOUNCEMENT still shipped"
    fi
}

# --- the recipe ---------------------------------------------------------------

check_recipe() {
    local summary

    if cmp -s "$CTX/system_files$RECIPE" "$RECIPE"; then
        echo "OK: $RECIPE is the vendored copy"
    else
        echo "FAIL: $RECIPE is not the vendored copy"
    fi

    summary=$(just --justfile "$RECIPE" --summary 2>&1 || true)
    if [ "$summary" = "setup-sunshine" ]; then
        echo "OK: recipe file defines exactly setup-sunshine"
    else
        echo "FAIL: recipe summary: $summary"
    fi

    check_just_fmt "$RECIPE"
    check_recipe_help "$RECIPE" setup-sunshine

    if has_recipe /usr/share/ublue-os/justfile setup-sunshine; then
        echo "OK: base justfile still imports the recipe"
    else
        summary=$(just --justfile /usr/share/ublue-os/justfile --summary 2>&1 | head -n2)
        echo "FAIL: base justfile: $summary"
    fi
}

# --- main ---------------------------------------------------------------------

check_binary
check_copr_repo
check_user_unit
check_device_files
check_base_files
check_recipe
