#!/usr/bin/env bash
# Smoke test of 21-container-runtime.sh: the Docker CE and podman packages,
# the vendored Docker key and its pin, the sockets on and docker.service off,
# the nat module docker-in-docker loads, the docker group where NSS reads it,
# and the groups boot hook exercised on a fixture.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
# shellcheck source=../lib/log.sh
source "$CTX/build_files/lib/log.sh"
# shellcheck source=../lib/gpg.sh
source "$CTX/build_files/lib/gpg.sh"

KEY=/etc/pki/rpm-gpg/RPM-GPG-KEY-docker-ce
DOCKER_REPO=/etc/yum.repos.d/docker-ce.repo
MODULES_LOAD=/usr/lib/modules-load.d/ip_tables.conf
GROUPS_HOOK=/usr/share/ublue-os/system-setup.hooks.d/10-bazzite-mx-groups.sh
WRONG_FINGERPRINT=0000000000000000000000000000000000000000

# --- the image ----------------------------------------------------------------

check_packages() {
    check_pkg containerd.io docker-buildx-plugin docker-ce docker-ce-cli \
        docker-compose-plugin bcvk podman podman-compose podman-machine podman-tui

    if rpm -q docker-model-plugin > /dev/null 2>&1; then
        echo "FAIL: docker-model-plugin installed (left out on purpose)"
    else
        echo "OK: docker-model-plugin absent"
    fi
}

# The shipped key is the pinned one, the .repo reads it from the file, and
# dnf5 imported it into the rpm keyring at install.
check_docker_key() {
    local pinned=${KEY_FPR[$KEY]}
    local actual gpgkey_line

    actual=$(key_fingerprint "$KEY" || true)
    if [ "$actual" = "$pinned" ]; then
        echo "OK: $KEY fingerprint $pinned"
    else
        echo "FAIL: $KEY fingerprint $actual"
    fi

    # assert_key_fingerprint ends the build through fail_build, so it runs
    # in a subshell: its exit must not end the test.
    if (assert_key_fingerprint "$KEY" "$WRONG_FINGERPRINT") > /dev/null 2>&1; then
        echo "FAIL: assert_key_fingerprint accepted a wrong fingerprint"
    else
        echo "OK: assert_key_fingerprint refuses a wrong fingerprint"
    fi

    if grep -q "^gpgkey=file://$KEY$" "$DOCKER_REPO"; then
        echo "OK: docker-ce.repo reads the vendored key"
    else
        gpgkey_line=$(grep '^gpgkey' "$DOCKER_REPO" || true)
        echo "FAIL: docker-ce.repo gpgkey line: $gpgkey_line"
    fi

    check_rpm_key 621e9f35 "Docker"
}

check_sockets() {
    check_unit_state docker.socket enabled
    check_unit_state podman.socket enabled
    check_unit_state docker.service disabled "socket-activated"
}

check_nat_module() {
    local kernel=$1

    if grep -qx 'iptable_nat' "$MODULES_LOAD" \
        && modinfo -k "$kernel" iptable_nat > /dev/null 2>&1; then
        echo "OK: iptable_nat listed in modules-load.d and present for kernel $kernel"
    else
        echo "FAIL: iptable_nat missing from modules-load.d or from kernel $kernel"
    fi
}

# Created by the package's %post, relocated out of /etc/group by clean-stage.
check_docker_group() {
    local in_usr in_etc

    if grep -q '^docker:' /usr/lib/group && ! grep -q '^docker:' /etc/group; then
        echo "OK: docker group in /usr/lib/group, not in /etc/group"
    else
        in_usr=$(grep '^docker:' /usr/lib/group || echo none)
        in_etc=$(grep '^docker:' /etc/group || echo none)
        echo "FAIL: docker group: /usr/lib/group=$in_usr /etc/group=$in_etc"
    fi
}

# --- the groups hook on a fixture ---------------------------------------------

# A tree with two users, alice in wheel and bob not, and the image's own
# /usr/lib/group: the checks follow the hook's GROUPS_TARGET instead of
# repeating the list.
fixture_create() {
    local fixture

    fixture=$(mktemp -d)
    mkdir -p "$fixture/etc" "$fixture/usr/lib"

    printf 'root:x:0:0:root:/root:/bin/bash\n' > "$fixture/etc/passwd"
    printf 'alice:x:1000:1000::/home/alice:/bin/bash\n' >> "$fixture/etc/passwd"
    printf 'bob:x:1001:1001::/home/bob:/bin/bash\n' >> "$fixture/etc/passwd"
    printf 'root:x:0:\nwheel:x:10:alice\nalice:x:1000:\nbob:x:1001:\n' > "$fixture/etc/group"
    cp /usr/lib/group "$fixture/usr/lib/group"

    echo "$fixture"
}

run_hook() {
    local fixture=$1

    BAZZITE_MX_GROUPS_PREFIX=$fixture bash "$GROUPS_HOOK" 2>&1
}

# The groups the hook's summary line names, empty when there is no summary.
groups_summarised_in() {
    local output=$1

    sed -n 's/^bazzite-mx-groups: [0-9]* wheel user(s) in //p' <<< "$output"
}

# Status 0 when every group the hook summarised has alice as its only member
# and bob is in none of them.
wheel_user_in_every_group() {
    local fixture=$1
    local output=$2
    local groups group

    groups=$(groups_summarised_in "$output")
    if [ -z "$groups" ]; then
        return 1
    fi

    for group in $groups; do
        if ! grep -q "^${group}:[^:]*:[^:]*:alice$" "$fixture/etc/group"; then
            return 1
        fi
    done

    if grep -q '^docker:.*bob' "$fixture/etc/group"; then
        return 1
    fi

    return 0
}

check_hook_first_run() {
    local fixture=$1
    local output groups_in_fixture

    if output=$(run_hook "$fixture") && wheel_user_in_every_group "$fixture" "$output"; then
        echo "OK: hook adds the wheel user to $(groups_summarised_in "$output")"
    else
        groups_in_fixture=$(grep -E '^(docker|libvirt):' "$fixture/etc/group" || echo none)
        echo "FAIL: hook on fixture: $output; group file: $groups_in_fixture"
    fi
}

check_hook_second_run() {
    local fixture=$1
    local output

    if output=$(run_hook "$fixture") && wheel_user_in_every_group "$fixture" "$output" \
        && ! grep -q 'adding' <<< "$output"; then
        echo "OK: hook is idempotent on a second run"
    else
        echo "FAIL: second hook run: $output"
    fi
}

# The target groups removed from both files: the hook must name them and fail.
check_hook_missing_groups() {
    local fixture=$1
    local output

    : > "$fixture/usr/lib/group"
    sed -i '/^\(docker\|libvirt\):/d' "$fixture/etc/group"

    if output=$(run_hook "$fixture"); then
        echo "FAIL: hook exited 0 with the target groups missing from both files"
    elif grep -q 'ERROR: group(s) docker' <<< "$output"; then
        echo "OK: hook reports and fails on missing groups"
    else
        echo "FAIL: hook failed without naming the missing groups: $output"
    fi
}

# --- main ---------------------------------------------------------------------

kernel=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n1)

check_packages
check_docker_key
check_sockets
check_nat_module "$kernel"
check_docker_group

fixture=$(fixture_create)
check_hook_first_run "$fixture"
check_hook_second_run "$fixture"
check_hook_missing_groups "$fixture"
rm -rf "$fixture"
