#!/usr/bin/env bash
# Smoke test of 22-virtualization.sh: the packages, the modular libvirt
# daemons on and the monolithic one off, binfmt kept out, the KVM options,
# the tmpfiles list, the qemu user, the recipe that replaces the base's,
# the helper that keeps libvirt's bridges forwarding under Docker's
# firewall, and the Portal's virtualization group removed.
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

KVM_OPTIONS=/usr/lib/modprobe.d/bazzite-mx-kvm.conf
TMPFILES=/usr/lib/tmpfiles.d/bazzite-mx-virt.conf
RECIPE=/usr/share/ublue-os/just/84-bazzite-virt.just
KVMFR_HELPER=/usr/libexec/bazzite-dx-kvmfr-setup
LIBVIRT_FORWARD=/usr/libexec/bazzite-mx-libvirt-forward
DOCKER_DROPIN=/usr/lib/systemd/system/docker.service.d/bazzite-mx-libvirt.conf
LIBVIRTD_SETUP=/usr/lib/systemd/system/bazzite-libvirtd-setup.service

# --- the image ----------------------------------------------------------------

check_packages() {
    local package mesa_vendor

    check_pkg libvirt libvirt-daemon-kvm libvirt-nss qemu-kvm qemu-img virt-manager \
        virt-viewer virt-install edk2-ovmf swtpm swtpm-tools guestfs-tools waypipe \
        quickemu ublue-os-libvirt-workarounds

    check_flatpak_deny 'org.virt_manager.virt-manager/*'

    # mesa-demos comes from Fedora through a lifted exclude; Mesa itself must
    # still be Terra's.
    mesa_vendor=$(rpm -q --qf '%{VENDOR}' mesa-libGL.x86_64 2>&1 || true)

    if rpm -q mesa-demos > /dev/null && [ "$mesa_vendor" = "Terra" ]; then
        echo "OK: mesa-demos $(rpm -q --qf '%{VERSION}' mesa-demos) installed, Mesa still Terra's"
    else
        echo "FAIL: mesa-demos $(rpm -q mesa-demos 2>&1 | head -n1 | on_one_line 'no output');" \
            "mesa-libGL vendor" \
            "${mesa_vendor:-empty}"
    fi

    for package in qemu-user-binfmt qemu-user-static; do
        if rpm -q "$package" > /dev/null 2>&1; then
            echo "FAIL: $package installed (the image keeps binfmt out)"
        else
            echo "OK: $package absent"
        fi
    done
}

check_daemons() {
    local unit

    for unit in virtqemud.socket virtqemud.service ublue-os-libvirt-workarounds.service; do
        check_unit_state "$unit" enabled
    done

    check_unit_state libvirtd.service disabled "modular daemons only"

    if [ ! -e "$LIBVIRTD_SETUP" ]; then
        echo "OK: $LIBVIRTD_SETUP removed (it would enable libvirtd)"
    else
        echo "FAIL: $LIBVIRTD_SETUP ships: a link Bazzite's virt-on left enables libvirtd"
    fi
}

check_kvm_options() {
    local kernel=$1 parameters options

    # Both options must exist in the kernel's kvm module: the kernel loads kvm
    # without an unknown one and only warns (kernel/module/main.c).
    parameters=$(modinfo -k "$kernel" -p kvm 2> /dev/null || true)

    if grep -qx 'options kvm ignore_msrs=1 report_ignored_msrs=0' "$KVM_OPTIONS" 2> /dev/null \
        && grep -q '^ignore_msrs:' <<< "$parameters" \
        && grep -q '^report_ignored_msrs:' <<< "$parameters"; then
        echo "OK: kvm options set in modprobe.d and known to kernel $kernel"
    else
        options=$(cat "$KVM_OPTIONS" 2>&1 | grep -vE '^(#|$)' \
            | on_one_line 'no line beyond comments' || true)
        echo "FAIL: kvm options: $options"
    fi

    if modinfo -k "$kernel" kvmfr > /dev/null 2>&1; then
        echo "OK: kvmfr module present for kernel $kernel (base)"
    else
        echo "FAIL: kvmfr module missing for kernel $kernel"
    fi
}

# One "<mode> <user> <group> <path>" line per packaged /var directory, the
# mode as tmpfiles writes it; /var/log/libvirt is the base's own line.
packaged_var_directories() {
    rpm -q --qf '[%{FILEMODES:octal} %{FILEUSERNAME} %{FILEGROUPNAME} %{FILENAMES}\n]' \
        libvirt-daemon-common libvirt-daemon-driver-qemu libvirt-daemon-driver-network \
        swtpm swtpm-tools \
        | awk '$4 ~ /^\/var\/(lib|log|cache)\// && $4 != "/var/log/libvirt" {
            print substr($1, length($1) - 3), $2, $3, $4
        }' \
        | sort -u
}

check_tmpfiles() {
    local directories mode user group directory missing=0

    if ! directories=$(packaged_var_directories 2> /dev/null) || [ -z "$directories" ]; then
        echo "FAIL: rpm does not list every libvirt and swtpm package, or no /var directory"
        return 0
    fi

    while read -r mode user group directory; do
        if ! grep -q "^d $directory $mode $user $group " "$TMPFILES" 2> /dev/null; then
            echo "FAIL: $directory packaged as $mode $user $group, not so in $TMPFILES"
            missing=1
        fi
    done <<< "$directories"

    if [ "$missing" -eq 0 ]; then
        echo "OK: every packaged /var directory listed in $TMPFILES with its owner and mode"
    fi

    if systemd-tmpfiles --dry-run --create "$TMPFILES" > /dev/null 2>&1; then
        echo "OK: $TMPFILES parses (dry run)"
    else
        echo "FAIL: systemd-tmpfiles rejects $TMPFILES"
    fi
}

# 95-clean-stage.sh moves the accounts the packages' %post created where NSS
# reads them, and qemu:///system runs its domains as this one: without the
# line no domain starts, /etc/passwd having been reset to root alone
# (tests/95-clean-stage.sh refuses any other line there).
check_qemu_user() {
    if grep -q '^qemu:' /usr/lib/passwd 2> /dev/null; then
        echo "OK: qemu user in /usr/lib/passwd"
    else
        echo "FAIL: no qemu user in /usr/lib/passwd"
    fi
}

names_assigned_by() {
    local script=$1

    grep -vE '^[[:space:]]*#' "$script" 2> /dev/null \
        | grep -oE '(^|[[:space:]])[A-Za-z_][A-Za-z0-9_]*=' \
        | tr -d ' =' \
        | sort -u
}

# The helper sources ujust.sh, whose libraries declare their colour and
# formatting names readonly; an assignment to one of them fails at every run
# (docs/gotchas.md § `ujust.sh` declares its colour and formatting names
# readonly). Both lists are read from the image, and an empty list on either
# side is a failure: the probe cannot see, and a pass would prove nothing.
check_kvmfr_helper() {
    local readonly_names assigned clash

    readonly_names=$(grep -hoE '^declare -r [A-Za-z_]+' /usr/lib/ujust/*.sh 2> /dev/null \
        | awk '{ print $3 }' | sort -u || true)
    assigned=$(names_assigned_by "$KVMFR_HELPER" || true)
    clash=$(grep -xF -f <(echo "$readonly_names") <<< "$assigned" || true)

    if [ -z "$readonly_names" ]; then
        echo "FAIL: no readonly name found under /usr/lib/ujust" \
            "(the ujust libraries changed shape?)"
    elif [ ! -x "$KVMFR_HELPER" ] || [ -z "$assigned" ]; then
        echo "FAIL: $KVMFR_HELPER missing, not executable, or no assignment read from it"
    elif [ -z "$clash" ]; then
        echo "OK: kvmfr helper assigns none of the $(wc -l <<< "$readonly_names") names" \
            "ujust.sh declares readonly"
    else
        echo "FAIL: kvmfr helper assigns readonly ujust.sh names:" \
            "$(on_one_line 'none' <<< "$clash")"
    fi
}

# Known-bad: an empty answer (no terminal) went on to write the modprobe note
# and the rest.
check_kvmfr_helper_stops_without_ok() {
    if "$KVMFR_HELPER" < /dev/null > /dev/null 2>&1 && [ ! -e /etc/modprobe.d/kvmfr.conf ]; then
        echo "OK: kvmfr helper changes nothing without an Ok"
    else
        echo "FAIL: kvmfr helper went on without an Ok"
    fi
}

# --- forwarding for the libvirt bridges under Docker --------------------------

# The stub keeps chains and rules in STATE, one per line, and answers -S, -N,
# -F, -A, -I and -C on them; REFUSE_WRITE=1 makes every write fail, the way a
# netfilter that refuses the rule would, READ_FAILS=1 makes -S exit 4, the
# way iptables does when it cannot read the rule set, and CHECK_FAILS=1 the -C.
write_iptables_stub() {
    local stub=$1

    cat > "$stub" << 'STUB'
#!/usr/bin/env bash
set -euo pipefail

refuse_writes() {
    if [ "${REFUSE_WRITE:-0}" = 1 ]; then
        echo "iptables: write refused" >&2
        exit 1
    fi
}

case $1 in
    -S)
        if [ "${READ_FAILS:-0}" = 1 ]; then
            echo "iptables: Could not fetch rule set generation id" >&2
            exit 4
        fi

        grep -qx "chain $2" "$STATE" 2> /dev/null
        ;;
    -C)
        if [ "${CHECK_FAILS:-0}" = 1 ]; then
            echo "iptables: Could not fetch rule set generation id" >&2
            exit 4
        fi

        shift
        grep -qxF "rule $*" "$STATE" 2> /dev/null
        ;;
    -N)
        refuse_writes
        echo "chain $2" >> "$STATE"
        ;;
    -F)
        refuse_writes
        kept=$(grep -v "^rule $2 " "$STATE" || true)
        echo "$kept" > "$STATE"
        ;;
    -A | -I)
        refuse_writes
        shift
        echo "rule $*" >> "$STATE"
        ;;
    *)
        echo "stub: unexpected $*" >&2
        exit 2
        ;;
esac
STUB
    chmod +x "$stub"
}

run_libvirt_forward() {
    IPTABLES=$1 STATE=$2 "$LIBVIRT_FORWARD" 2>&1
}

# The chain and the jump the helper leaves behind, in the order it writes them.
expected_libvirt_forward_state() {
    printf '%s\n' \
        'chain DOCKER-USER' \
        'chain BAZZITE-MX-LIBVIRT' \
        'rule BAZZITE-MX-LIBVIRT -i virbr+ -o docker0 -j RETURN' \
        'rule BAZZITE-MX-LIBVIRT -i virbr+ -o br-+ -j RETURN' \
        'rule BAZZITE-MX-LIBVIRT -i virbr+ -j ACCEPT' \
        'rule BAZZITE-MX-LIBVIRT -o virbr+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT' \
        'rule DOCKER-USER -j BAZZITE-MX-LIBVIRT'
}

check_libvirt_forward_files() {
    local merged

    # systemd-analyze verify exits 0 on every drop-in defect (unknown key,
    # relative or missing path) and would prove nothing: the merged unit is
    # what systemd reads, so the line is looked for there.
    merged=$(systemctl cat docker.service 2> /dev/null || true)

    if grep -qx "ExecStartPost=-$LIBVIRT_FORWARD" <<< "$merged"; then
        echo "OK: systemd merges the drop-in into docker.service"
    else
        echo "FAIL: systemd does not merge $DOCKER_DROPIN into docker.service"
    fi
}

check_libvirt_forward_builds_the_chain() {
    local stub=$1 state=$2
    local output

    echo "chain DOCKER-USER" > "$state"

    if output=$(run_libvirt_forward "$stub" "$state") \
        && grep -q 'chain BAZZITE-MX-LIBVIRT rebuilt, 4 rules' <<< "$output" \
        && grep -q 'jump to BAZZITE-MX-LIBVIRT inserted' <<< "$output" \
        && [ "$(cat "$state")" = "$(expected_libvirt_forward_state)" ]; then
        echo "OK: helper builds its chain, four rules in order, and the jump from DOCKER-USER"
    else
        echo "FAIL: helper on an empty DOCKER-USER:" \
            "$(on_one_line 'no output' <<< "$output"); state:" \
            "$(cat "$state" 2>&1 | on_one_line 'empty' ';')"
    fi
}

check_libvirt_forward_is_idempotent() {
    local stub=$1 state=$2
    local before output

    # The stub appends where a flush removes, so only the set is compared.
    before=$(sort "$state" || true)

    if output=$(run_libvirt_forward "$stub" "$state") \
        && grep -q 'chain BAZZITE-MX-LIBVIRT rebuilt, 4 rules' <<< "$output" \
        && grep -q 'jump to BAZZITE-MX-LIBVIRT present' <<< "$output" \
        && [ "$(sort "$state")" = "$before" ]; then
        echo "OK: a second run rebuilds the chain and leaves the jump alone"
    else
        echo "FAIL: helper on a second run: $(on_one_line 'no output' <<< "$output"); state:" \
            "$(cat "$state" 2>&1 | on_one_line 'empty' ';')"
    fi
}

# No chain means Docker wrote no iptables rules and set no DROP policy:
# nothing to lift, and nothing may be written.
check_libvirt_forward_skips_a_missing_chain() {
    local stub=$1 state=$2
    local output

    : > "$state"

    if output=$(run_libvirt_forward "$stub" "$state") \
        && grep -q 'no DOCKER-USER chain .*: nothing to do' <<< "$output" \
        && [ ! -s "$state" ]; then
        echo "OK: helper does nothing without a DOCKER-USER chain"
    else
        echo "FAIL: helper without the chain: $(on_one_line 'no output' <<< "$output"); state:" \
            "$(cat "$state" 2>&1 | on_one_line 'empty' ';')"
    fi
}

# Known-bad: a `-C` that fails for any reason but "absent" (status 4 under
# CHECK_FAILS) once read as absent, and a second jump went in at every start.
check_libvirt_forward_reports_an_unreadable_jump() {
    local stub=$1 state=$2
    local output

    echo "chain DOCKER-USER" > "$state"

    if output=$(CHECK_FAILS=1 run_libvirt_forward "$stub" "$state"); then
        echo "FAIL: helper exited 0 on an unreadable jump check:" \
            "$(on_one_line 'no output' <<< "$output")"
    elif grep -q 'ERROR: cannot check the DOCKER-USER jump to BAZZITE-MX-LIBVIRT' <<< "$output" \
        && grep -q '(iptables exit 4)' <<< "$output" \
        && ! grep -q '^rule DOCKER-USER -j BAZZITE-MX-LIBVIRT$' "$state" 2> /dev/null; then
        echo "OK: helper reports an unreadable jump check and inserts nothing"
    else
        echo "FAIL: helper on an unreadable jump check:" \
            "$(on_one_line 'no output' <<< "$output"); state:" \
            "$(cat "$state" 2>&1 | on_one_line 'empty')"
    fi
}

# A read that fails for another reason than the absent chain (status 1) is
# not a chain that is absent: the helper must say so and stop with the 1 its
# header promises.
check_libvirt_forward_reports_an_unreadable_chain() {
    local stub=$1 state=$2
    local output status

    echo "chain DOCKER-USER" > "$state"

    if output=$(READ_FAILS=1 run_libvirt_forward "$stub" "$state"); then
        status=0
    else
        status=$?
    fi

    if [ "$status" -eq 1 ] \
        && grep -q 'ERROR: cannot read iptables chain DOCKER-USER (iptables exit 4)' <<< "$output" \
        && [ "$(cat "$state")" = "chain DOCKER-USER" ]; then
        echo "OK: helper reports an unreadable rule set and exits 1"
    else
        echo "FAIL: helper on an unreadable rule set (exit $status):" \
            "$(on_one_line 'no output' <<< "$output")"
    fi
}

check_libvirt_forward_reports_a_refused_write() {
    local stub=$1 state=$2
    local output

    echo "chain DOCKER-USER" > "$state"

    if output=$(REFUSE_WRITE=1 run_libvirt_forward "$stub" "$state"); then
        echo "FAIL: helper exited 0 on a refused write: $(on_one_line 'no output' <<< "$output")"
    elif grep -q "cannot write iptables rule: -N BAZZITE-MX-LIBVIRT (iptables: write refused)" \
        <<< "$output" \
        && [ "$(wc -l <<< "$output")" -eq 1 ]; then
        echo "OK: helper reports a refused write on one line, iptables' reason inside"
    else
        echo "FAIL: helper on a refused write: $(on_one_line 'no output' <<< "$output")"
    fi
}

# The rules go in from a fixture iptables: a build container has no
# netfilter to write, and the real chain is proven on a host
# (docs/gotchas.md § Docker's `FORWARD` policy cuts libvirt's NAT guests off).
check_libvirt_forward() {
    local fixture

    check_libvirt_forward_files

    fixture=$(mktemp -d)
    write_iptables_stub "$fixture/iptables"
    check_libvirt_forward_builds_the_chain "$fixture/iptables" "$fixture/state"
    check_libvirt_forward_is_idempotent "$fixture/iptables" "$fixture/state"
    check_libvirt_forward_skips_a_missing_chain "$fixture/iptables" "$fixture/state"
    check_libvirt_forward_reports_an_unreadable_chain "$fixture/iptables" "$fixture/state"
    check_libvirt_forward_reports_an_unreadable_jump "$fixture/iptables" "$fixture/state"
    check_libvirt_forward_reports_a_refused_write "$fixture/iptables" "$fixture/state"
    rm -rf "$fixture"
}

# --- main ---------------------------------------------------------------------

kernel=$(kernel_version)

check_packages
check_daemons
check_kvm_options "$kernel"
check_tmpfiles
check_qemu_user
check_recipe_help "$RECIPE" setup-virtualization
check_kvmfr_helper
check_kvmfr_helper_stops_without_ok
check_libvirt_forward
check_portal_group_removed virtualization automounting
