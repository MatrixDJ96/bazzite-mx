#!/usr/bin/env bash
# Smoke test of /usr/libexec/bazzite-mx-verify-host, the helper behind ujust
# verify-host, on host-shaped fixtures: a migrated host, one before the
# migration, one on the signed transport with the wrong tag and key, an MSI
# host that turned setup-msi off, and a flavour that does not match the GPU.
# What needs a booted host is proven there.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines. The test
# itself stops when a file the migrated fixture copies from the image is
# missing.
set -euo pipefail

# shellcheck source=../lib.sh
source "$(dirname "$(realpath "$0")")/../lib.sh"

VERIFY_HOST=/usr/libexec/bazzite-mx-verify-host
IMAGE_INFO=/usr/share/ublue-os/image-info.json
NVIDIA_GPU_LINE='01:00.0 0300: 10de:2c05 (rev a1)'

# The checks the migrated fixture must report, one pattern per OK line, the
# set every flavour prints: the two NVIDIA flavours print one more, `nvidia
# module loaded`, left out here because its counterpart `nvidia module not
# loaded` is required on their signed-but-wrong fixture.
MIGRATED_OK_CHECKS=(
    'bootc status:'
    'origin uses the signed transport'
    'origin tag'
    'no layered'
    "initramfs is the image's"
    'policy.json: ghcr.io/matrixdj96 is sigstoreSigned'
    'policy.json: default is reject'
    'registries.d:'
    'MSI host: msi_ec'
    'MSI host: acpi_ec'
    'no MSI residue'
    'NVIDIA'
    'no ntfsplus residue'
    'no ntfsplus kernel argument'
    'no Firefox Flatpak'
    "the image's .repo files"
)

# --- the host fixtures --------------------------------------------------------

# fixture_migrated_host <dir> <image name>: a migrated MSI host on the signed
# transport, every check green; the file setup-msi writes is present and
# must not be read as residue, and a base .repo the host edited and an
# image's one it deleted are not the image's to restore.
fixture_migrated_host() {
    local fixture=$1
    local image=$2
    local booted_image="ghcr.io/matrixdj96/$image:stable"
    local origin="ostree-image-signed:docker://$booted_image"
    local source

    mkdir -p "$fixture/cmd" "$fixture/etc/containers/registries.d" "$fixture/etc/pki/containers" \
        "$fixture/etc/modprobe.d" "$fixture/etc/modules-load.d" "$fixture/usr/share/ublue-os" \
        "$fixture/sys/class/dmi/id" "$fixture/proc" "$fixture/usr/etc" \
        "$fixture/usr/lib/bazzite-mx/build-state"

    for source in "$IMAGE_INFO:usr/share/ublue-os" /etc/containers/policy.json:etc/containers \
        /etc/containers/registries.d/matrixdj96.yaml:etc/containers/registries.d \
        /etc/pki/containers/matrixdj96.pub:etc/pki/containers \
        /usr/lib/bazzite-mx/build-state/repos.base.sha256:usr/lib/bazzite-mx/build-state; do
        cp "${source%%:*}" "$fixture/${source#*:}/"
    done

    cp -r /etc/yum.repos.d "$fixture/usr/etc/"
    cp -r /etc/yum.repos.d "$fixture/etc/"
    echo '# a host edit' >> "$fixture/etc/yum.repos.d/fedora.repo"
    rm "$fixture/etc/yum.repos.d/vscode.repo"

    printf 'Micro-Star International Co., Ltd.\n' > "$fixture/sys/class/dmi/id/sys_vendor"
    printf 'msi_ec 16384 0 - Live 0x0\nacpi_ec 12288 0 - Live 0x0\nnvidia 1000 0 - Live 0x0\n' \
        > "$fixture/proc/modules"
    printf 'msi-ec\nacpi_ec\n' > "$fixture/etc/modules-load.d/bazzite-mx-msi.conf"
    printf 'root=UUID=1 rw\n' > "$fixture/cmd/kargs"
    printf 'org.kde.okular\n' > "$fixture/cmd/flatpaks"

    if [[ $image == *nvidia* ]]; then
        printf '%s\n' "$NVIDIA_GPU_LINE" > "$fixture/cmd/lspci-nvidia"
    else
        : > "$fixture/cmd/lspci-nvidia"
    fi

    fixture_write_bootc_status "$fixture" false "{\"image\":{\"image\":\"$booted_image\"}}"
    fixture_write_rpm_ostree_status "$fixture" "$origin" '"packages":[],
        "requested-local-packages":[],"requested-base-removals":[],
        "regenerate-initramfs":false' 44.20260903
}

fixture_write_bootc_status() {
    local fixture=$1
    local incompatible=$2
    local image_json=$3

    printf '{"status":{"staged":null,"booted":{"incompatible":%s,"pinned":false,"image":%s}}}\n' \
        "$incompatible" "$image_json" > "$fixture/cmd/bootc-status.json"
}

# fixture_write_rpm_ostree_status <dir> <origin> <extra fields> <version>:
# one booted deployment; the extra fields are the mutation keys, verbatim.
fixture_write_rpm_ostree_status() {
    local fixture=$1
    local origin=$2
    local extra_fields=$3
    local version=$4

    local deployment='{"booted":true,"staged":false,%s,%s,"pinned":false,"version":"%s"}'

    printf "{\"deployments\":[$deployment]}\n" \
        "\"container-image-reference\":\"$origin\"" "$extra_fields" "$version" \
        | tr -d '\n' > "$fixture/cmd/rpm-ostree-status.json"
    echo >> "$fixture/cmd/rpm-ostree-status.json"
}

# run_verify_host <fixture>: verify-host on the fixture, its output in
# VERIFY_HOST_OUTPUT and its exit status in VERIFY_HOST_STATUS.
run_verify_host() {
    local fixture=$1

    if VERIFY_HOST_OUTPUT=$(FIXTURE=$fixture "$VERIFY_HOST" 2>&1); then
        VERIFY_HOST_STATUS=0
    else
        VERIFY_HOST_STATUS=$?
    fi
}

# unreported_of <output> <pattern>...: the patterns no line of the output
# carries, one per line. A count of matching lines would not do: a line
# printed twice pays for a check that stopped reporting.
unreported_of() {
    local output=$1
    shift
    local pattern

    for pattern in "$@"; do
        if ! grep -qF "$pattern" <<< "$output"; then
            printf '%s\n' "$pattern"
        fi
    done
}

check_verify_host_on_migrated_fixture() {
    local fixture=$1
    local output ok_lines unreported

    run_verify_host "$fixture"
    output=$VERIFY_HOST_OUTPUT
    ok_lines=$(grep '^OK:' <<< "$output" || true)
    unreported=$(unreported_of "$ok_lines" "${MIGRATED_OK_CHECKS[@]}")

    if [ "$VERIFY_HOST_STATUS" -eq 0 ] && ! grep -q '^FAIL:' <<< "$output" \
        && [ -z "$unreported" ]; then
        echo "OK: verify-host passes on the migrated fixture" \
            "(every check reported, setup-msi's file not residue)"
    else
        echo "FAIL: verify-host on the migrated fixture (exit $VERIFY_HOST_STATUS):" \
            "checks that did not report: $(on_one_line none ',' <<< "$unreported");" \
            "$(grep -E '^(FAIL|ERROR)' <<< "$output" | on_one_line 'no matching line')"
    fi
}

# Known-bad: a host before the migration, with every defect at once. Each
# one must be named on its own line.
check_verify_host_on_unmigrated_fixture() {
    local good=$1
    local image=$2
    local fixture=$good/../bad
    local origin="ostree-unverified-registry:ghcr.io/matrixdj96/$image:44.20260831"
    local output fail_lines unreported
    local mutations='1password firefox sddm-0.21-1.fc44.x86_64 teams-for-linux'
    local expected_fails=(
        'bootc status reports'
        'origin is not ostree-image-signed'
        "rpm-ostree mutations in the origin: $mutations"
        'initramfs is regenerated locally'
        'policy.json has no sigstoreSigned scope'
        'MSI host: msi_ec not loaded'
        'MSI host: acpi_ec not loaded'
        'ntfsplus residue: /etc/modprobe.d/ntfsplus.conf'
        'MSI residue: /etc/modules-load.d/msi-ec.conf'
        "/etc/yum.repos.d/1password.repo differs from the image's copy"
    )

    cp -a "$good/." "$fixture/"
    fixture_write_bootc_status "$fixture" true null
    fixture_write_rpm_ostree_status "$fixture" "$origin" '"packages":[],
        "requested-packages":["1password"],"requested-local-packages":["teams-for-linux"],
        "requested-base-removals":["firefox"],
        "requested-base-local-replacements":["sddm-0.21-1.fc44.x86_64"],
        "regenerate-initramfs":true,"initramfs-args":["--hostonly"]' 44.20260831
    jq 'del(.transports.docker["ghcr.io/matrixdj96"])' "$good/etc/containers/policy.json" \
        > "$fixture/etc/containers/policy.json"
    printf 'nvidia 1000 0 - Live 0x0\n' > "$fixture/proc/modules"
    printf 'blacklist ntfsplus\n' > "$fixture/etc/modprobe.d/ntfsplus.conf"
    printf 'msi-ec\n' > "$fixture/etc/modules-load.d/msi-ec.conf"
    sed -i 's/^enabled=0/enabled=1/' "$fixture/etc/yum.repos.d/1password.repo"
    printf 'org.mozilla.firefox\n' > "$fixture/cmd/flatpaks"

    run_verify_host "$fixture"
    output=$VERIFY_HOST_OUTPUT
    fail_lines=$(grep -E '^FAIL:' <<< "$output" || true)
    unreported=$(unreported_of "$fail_lines" "${expected_fails[@]}")

    if [ "$VERIFY_HOST_STATUS" -eq 1 ] && [ -z "$unreported" ] \
        && grep -q '^INFO: the Firefox Flatpak is still installed' <<< "$output"; then
        echo "OK: verify-host names every defect of the unmigrated fixture" \
            "(${#expected_fails[@]} defects named, exit 1, Firefox Flatpak reported)"
    else
        echo "FAIL: verify-host on the unmigrated fixture: exit $VERIFY_HOST_STATUS," \
            "defects not named: $(on_one_line none ',' <<< "$unreported");" \
            "$(grep -E '^(FAIL|INFO|ERROR)' <<< "$output" | on_one_line 'no matching line')"
    fi
}

# Known-bad: a host on the signed transport with every remaining defect at
# once: a dated tag, a policy whose key is missing and whose default is not
# reject, registries.d without the attachments, an NVIDIA GPU (refused by
# bazzite-mx) with the module unloaded, a kernel argument naming ntfsplus.
check_verify_host_on_signed_but_wrong_fixture() {
    local good=$1
    local image=$2
    local fixture=$good/../bad2
    local origin policy_rewrite output fail_lines unreported missing_key
    local expected_fails=()
    local gpu_fail='NVIDIA GPU present but the image is' gpu_not='nvidia module not loaded'

    if [[ $image == *nvidia* ]]; then
        gpu_fail='nvidia module not loaded (nvidia-smi, journalctl -k -b)'
        gpu_not='NVIDIA GPU present but the image is'
    fi

    if [[ $image == *nvidia-open ]]; then
        gpu_fail='nvidia module not loaded (nvidia-smi, journalctl -k -b; a Maxwell, Pascal or'
        gpu_fail+=' Volta GPU needs bazzite-mx-nvidia)'
    fi

    origin="ostree-image-signed:docker://ghcr.io/matrixdj96/$image:44.20260831"
    policy_rewrite='.default = [{"type":"insecureAcceptAnything"}]
        | .transports.docker["ghcr.io/matrixdj96"][0].keyPath = "/etc/pki/containers/missing.pub"'

    cp -a "$good/." "$fixture/"
    fixture_write_rpm_ostree_status "$fixture" "$origin" '"packages":[],
        "regenerate-initramfs":false' 44.20260831
    jq "$policy_rewrite" "$good/etc/containers/policy.json" > "$fixture/etc/containers/policy.json"
    printf 'docker:\n  ghcr.io/matrixdj96:\n    use-sigstore-attachments: false\n' \
        > "$fixture/etc/containers/registries.d/matrixdj96.yaml"
    printf '%s\n' "$NVIDIA_GPU_LINE" > "$fixture/cmd/lspci-nvidia"
    printf 'msi_ec 16384 0 - Live 0x0\nacpi_ec 12288 0 - Live 0x0\n' > "$fixture/proc/modules"
    printf 'root=UUID=1 rw module_blacklist=ntfsplus\n' > "$fixture/cmd/kargs"

    missing_key='policy.json: ghcr.io/matrixdj96 scope names key'
    missing_key+=" '/etc/pki/containers/missing.pub', which is missing"
    expected_fails=(
        'origin tag is 44.20260831, not stable'
        "$missing_key"
        'policy.json: default is'
        'registries.d/matrixdj96.yaml missing or without use-sigstore-attachments'
        "$gpu_fail"
        'kernel arguments mention ntfsplus: module_blacklist=ntfsplus'
    )

    run_verify_host "$fixture"
    output=$VERIFY_HOST_OUTPUT
    fail_lines=$(grep -E '^FAIL:' <<< "$output" || true)
    unreported=$(unreported_of "$fail_lines" "${expected_fails[@]}")

    if [ "$VERIFY_HOST_STATUS" -eq 1 ] && [ -z "$unreported" ] \
        && ! grep -qF "$gpu_not" <<< "$fail_lines"; then
        echo "OK: verify-host names every defect of the signed-but-wrong fixture" \
            "(${#expected_fails[@]} defects named, exit 1)"
    else
        echo "FAIL: verify-host on the signed-but-wrong fixture: exit $VERIFY_HOST_STATUS," \
            "defects not named: $(on_one_line none ',' <<< "$unreported");" \
            "$(grep -E '^(FAIL|ERROR)' <<< "$output" | on_one_line 'no matching line')"
    fi
}

# An MSI host that ran `setup-msi disable`: the modules-load file is gone and
# the modules are unloaded. That is the state the recipe leaves, so the two
# modules are not expected and the run stays green; the residue check still
# reports a modules-load file of the host's own.
check_verify_host_on_msi_without_optin_fixture() {
    local good=$1
    local fixture=$good/../msi-off
    local output

    cp -a "$good/." "$fixture/"
    rm -f "$fixture/etc/modules-load.d/bazzite-mx-msi.conf"
    printf 'nvidia 1000 0 - Live 0x0\n' > "$fixture/proc/modules"

    run_verify_host "$fixture"
    output=$VERIFY_HOST_OUTPUT

    if [ "$VERIFY_HOST_STATUS" -eq 0 ] && ! grep -q '^FAIL:' <<< "$output" \
        && grep -q '^SKIP: MSI host without the setup-msi opt-in' <<< "$output"; then
        echo "OK: verify-host skips the MSI modules on a host that ran setup-msi disable"
    else
        echo "FAIL: verify-host on the MSI host without the opt-in" \
            "(exit $VERIFY_HOST_STATUS):" \
            "$(grep -E '^(FAIL|SKIP).*MSI' <<< "$output" | on_one_line 'no matching line')"
    fi
}

# A host without an NVIDIA GPU on an NVIDIA flavour is a defect; the other
# direction is the signed-but-wrong fixture's.
check_verify_host_on_gpu_mismatch() {
    local good=$1
    local fixture=$good/../gpu
    local output

    cp -a "$good/." "$fixture/"
    : > "$fixture/cmd/lspci-nvidia"

    run_verify_host "$fixture"
    output=$VERIFY_HOST_OUTPUT

    if grep -q '^FAIL: no NVIDIA GPU on the bus but the image is' <<< "$output"; then
        echo "OK: verify-host refuses a flavour that does not match the GPU"
    else
        echo "FAIL: verify-host GPU/flavour check:" \
            "$(grep -E '^(FAIL|OK).*(GPU|nvidia)' <<< "$output" | on_one_line 'no matching line')"
    fi
}

# --- main ---------------------------------------------------------------------

work=$(mktemp -d)
image=$(jq -r '."image-name"' "$IMAGE_INFO" 2>&1 || true)
fixture_migrated_host "$work/ok" "$image"
check_verify_host_on_migrated_fixture "$work/ok"
check_verify_host_on_unmigrated_fixture "$work/ok" "$image"
check_verify_host_on_signed_but_wrong_fixture "$work/ok" "$image"
check_verify_host_on_msi_without_optin_fixture "$work/ok"

if [[ $image == *nvidia* ]]; then
    check_verify_host_on_gpu_mismatch "$work/ok"
fi

rm -rf "$work"
