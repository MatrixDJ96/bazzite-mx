#!/usr/bin/env bash
# Smoke test of 21-container-runtime.sh: the Docker CE, podman and bcvk
# packages, the vendored Docker key and its pin, the sockets on and
# docker.service off, the nat module docker-in-docker loads, and the groups
# boot hook exercised on a fixture; tests/01 and tests/95 own where the docker
# group lives.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines. The test
# itself stops when kernel_version finds two kernels or none.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
# shellcheck source=../lib/log.sh
source "$CTX/build_files/lib/log.sh"
# shellcheck source=../lib/kmod.sh
source "$CTX/build_files/lib/kmod.sh"

KEY=/etc/pki/rpm-gpg/RPM-GPG-KEY-docker-ce
DOCKER_REPO=/etc/yum.repos.d/docker-ce.repo
MODULES_LOAD=/usr/lib/modules-load.d/ip_tables.conf
GROUPS_HOOK=/usr/share/ublue-os/system-setup.hooks.d/10-bazzite-mx-groups.sh
WRONG_FINGERPRINT=0000000000000000000000000000000000000000

# --- the image ----------------------------------------------------------------

check_packages() {
    check_pkg containerd.io docker-buildx-plugin docker-ce docker-ce-cli \
        docker-compose-plugin bcvk podman podman-compose podman-machine podman-tui
}

check_docker_key() {
    check_key_fingerprint "$KEY"

    # assert_key_fingerprint ends the build through fail_build, so it runs
    # in a subshell: its exit must not end the test.
    if (assert_key_fingerprint "$KEY" "$WRONG_FINGERPRINT") > /dev/null 2>&1; then
        echo "FAIL: assert_key_fingerprint accepted a wrong fingerprint"
    else
        echo "OK: assert_key_fingerprint refuses a wrong fingerprint"
    fi

    check_repo_reads_key "$DOCKER_REPO" "$KEY"

    check_rpm_key 621e9f35 "Docker"
}

check_sockets() {
    check_unit_state docker.socket enabled
    check_unit_state podman.socket enabled
    check_unit_state docker.service disabled "socket-activated"
}

check_nat_module() {
    local kernel=$1

    if grep -qx 'iptable_nat' "$MODULES_LOAD" 2> /dev/null \
        && modinfo -k "$kernel" iptable_nat > /dev/null 2>&1; then
        echo "OK: iptable_nat listed in modules-load.d and present for kernel $kernel"
    else
        echo "FAIL: iptable_nat missing from modules-load.d or from kernel $kernel"
    fi
}

# --- the groups hook on a fixture ---------------------------------------------

# A tree with two users, alice in wheel and bob not, and the image's own
# /usr/lib/group: the checks take the groups from the image's sysusers file
# instead of repeating the list.
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

# The groups the image fixes, on one line: the `g` lines of the sysusers file
# the hook's header names, a record independent of the hook.
groups_the_image_fixes() {
    awk '$1 == "g" { printf "%s%s", sep, $2; sep = " " }' \
        /usr/lib/sysusers.d/bazzite-mx-groups.conf 2> /dev/null
}

# Status 0 when every group the image fixes has alice as its only member, bob
# in none.
wheel_user_in_every_group() {
    local fixture=$1
    local groups group

    groups=$(groups_the_image_fixes)

    if [ -z "$groups" ]; then
        return 1
    fi

    for group in $groups; do
        if ! grep -q "^${group}:[^:]*:[^:]*:alice$" "$fixture/etc/group" 2> /dev/null; then
            return 1
        fi
    done

    return 0
}

check_hook_first_run() {
    local fixture=$1
    local output groups_in_fixture

    if output=$(run_hook "$fixture") && wheel_user_in_every_group "$fixture"; then
        echo "OK: hook adds the wheel user to $(groups_the_image_fixes)"
    else
        groups_in_fixture=$(grep -E '^docker:' "$fixture/etc/group" 2>&1 \
            | on_one_line none || true)
        echo "FAIL: hook on fixture:" \
            "$(on_one_line 'no output' <<< "$output"); group file: $groups_in_fixture"
    fi
}

check_hook_second_run() {
    local fixture=$1
    local output

    if output=$(run_hook "$fixture") && wheel_user_in_every_group "$fixture" \
        && ! grep -q 'adding' <<< "$output"; then
        echo "OK: hook is idempotent on a second run"
    else
        echo "FAIL: second hook run: $(on_one_line 'no output' <<< "$output")"
    fi
}

# A host whose /etc/group carries docker on another gid than the image's
# takes the image's number, and a file with the old gid under /run or /etc
# follows while one in a home stays; a number another group holds is left.
check_hook_realigns_gids() {
    local fixture output docker_gid

    fixture=$(fixture_create)
    docker_gid=$(awk -F: '$1 == "docker" { print $3 }' "$fixture/usr/lib/group")
    printf 'docker:x:958:alice\n' >> "$fixture/etc/group"
    mkdir -p "$fixture/var/home/alice" "$fixture/run"
    : > "$fixture/run/docker.sock"
    : > "$fixture/etc/docker-f"
    : > "$fixture/var/home/alice/f"
    chgrp 958 "$fixture/run/docker.sock" "$fixture/etc/docker-f" "$fixture/var/home/alice/f"

    if output=$(run_hook "$fixture") \
        && grep -qx "docker:x:$docker_gid:alice" "$fixture/etc/group" \
        && [ "$(stat -c %g "$fixture/run/docker.sock")" = "$docker_gid" ] \
        && [ "$(stat -c %g "$fixture/etc/docker-f")" = "$docker_gid" ] \
        && [ "$(stat -c %g "$fixture/var/home/alice/f")" = 958 ]; then
        echo "OK: hook moves docker to the image's gid, its files with it, a home's left"
    else
        echo "FAIL: hook on gid 958: $(on_one_line 'no output' <<< "$output");" \
            "$(grep -E '^docker:' "$fixture/etc/group" | on_one_line none)"
    fi

    sed -i -e "s/^docker:x:$docker_gid:/docker:x:958:/" "$fixture/etc/group"
    printf 'squatter:x:%s:\n' "$docker_gid" >> "$fixture/etc/group"

    if output=$(run_hook "$fixture") && grep -qx 'docker:x:958:alice' "$fixture/etc/group" \
        && grep -q "docker keeps gid 958: the image's $docker_gid is squatter's" <<< "$output"; then
        echo "OK: hook leaves a gid whose image number another group holds"
    else
        echo "FAIL: hook with the image's docker gid taken:" \
            "$(on_one_line 'no output' <<< "$output")"
    fi

    rm -rf "$fixture"
}

# --- main ---------------------------------------------------------------------

kernel=$(kernel_version)

check_packages
check_docker_key
check_sockets
check_nat_module "$kernel"

fixture=$(fixture_create)
check_hook_first_run "$fixture"
check_hook_second_run "$fixture"
rm -rf "$fixture"
check_hook_realigns_gids
