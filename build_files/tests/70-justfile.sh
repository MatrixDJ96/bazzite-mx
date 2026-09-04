#!/usr/bin/env bash
# Smoke test of 70-justfile.sh: our recipe file imported once, every recipe
# reachable exactly once, the overridden base recipe cut out with the rest
# intact, and the helpers behind the recipes exercised on fixtures:
# verify-host on five host shapes, the Toolbox installer on a file:// feed.
# What needs a booted host is proven there.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
JUST_DIR=/usr/share/ublue-os/just
MASTER=/usr/share/ublue-os/justfile
OURS=$JUST_DIR/95-bazzite-mx.just
APPS=$JUST_DIR/82-bazzite-apps.just
SNAPSHOT=$BUILD_STATE/just.base.summary
OUR_RECIPES="install-jetbrains-toolbox migrate setup-dev setup-msi setup-ntfsplus setup-panels"
OUR_RECIPES+=" verify-host"
VERIFY_HOST=/usr/libexec/bazzite-mx-verify-host
TOOLBOX=/usr/libexec/bazzite-mx-jetbrains-toolbox
IMAGE_INFO=/usr/share/ublue-os/image-info.json
NVIDIA_GPU_LINE='01:00.0 0300: 10de:2c05 (rev a1)'

# --- the recipe files ---------------------------------------------------------

check_our_recipe_file() {
    local defined

    if cmp -s "$CTX/system_files$OURS" "$OURS"; then
        echo "OK: $OURS is the vendored copy"
    else
        echo "FAIL: $OURS missing or not the vendored copy"
    fi

    defined=$(recipe_set "$OURS" | tr '\n' ' ')
    if [ "$defined" = "$OUR_RECIPES " ]; then
        echo "OK: $OURS defines exactly: $OUR_RECIPES"
    else
        echo "FAIL: $OURS defines: $defined"
    fi
}

check_master_justfile() {
    local import_count master_set recipe missing="" duplicates

    import_count=$(grep -c "^import \"$OURS\"$" "$MASTER")
    if [ "$import_count" -eq 1 ]; then
        echo "OK: $MASTER imports $OURS once"
    else
        echo "FAIL: $MASTER imports $OURS $import_count times"
    fi

    master_set=$(recipe_set "$MASTER")
    for recipe in $OUR_RECIPES; do
        if ! grep -qx "$recipe" <<< "$master_set"; then
            missing="$missing $recipe"
        fi
    done
    if [ -z "$missing" ]; then
        echo "OK: ujust exposes every recipe of ours ($(wc -l <<< "$master_set") recipes in all)"
    else
        echo "FAIL: ujust does not expose:$missing"
    fi

    duplicates=$(recipe_set_of_every_file | sort | uniq -d)
    if [ -z "$duplicates" ]; then
        echo "OK: no recipe defined in two files"
    else
        echo "FAIL: recipes defined twice: $(tr '\n' ' ' <<< "$duplicates")"
    fi

    if just --justfile "$MASTER" --list > /dev/null 2>&1; then
        echo "OK: just --list works on the master justfile"
    else
        echo "FAIL: just --list: $(just --justfile "$MASTER" --list 2>&1 | head -n2)"
    fi
}

recipe_set_of_every_file() {
    local file

    for file in "$JUST_DIR"/*.just; do
        recipe_set "$file"
    done
}

# recorded_recipes_of <file name>: the recipes 00-prep.sh recorded for the
# base's file, one per line, sorted; empty when the snapshot has no row.
recorded_recipes_of() {
    local file=$1

    grep "^$file: " "$SNAPSHOT" \
        | sed 's/^[^:]*: //' \
        | tr ' ' '\n' \
        | sed '/^$/d' \
        | sort
}

# The base's recipe is gone from its file and ours is what ujust runs.
check_base_recipe_cut_out() {
    local recorded shown

    if ! grep -q '^install-jetbrains-toolbox' "$APPS" \
        && ! grep -q 'brew install --cask jetbrains-toolbox' "$APPS"; then
        echo "OK: the base's install-jetbrains-toolbox is cut out of $APPS"
    else
        echo "FAIL: $APPS still carries install-jetbrains-toolbox"
    fi

    recorded=$(recorded_recipes_of 82-bazzite-apps.just | grep -vx install-jetbrains-toolbox)
    if [ -n "$recorded" ] && [ "$(recipe_set "$APPS")" = "$recorded" ]; then
        echo "OK: $APPS keeps the base's other $(wc -l <<< "$recorded") recipes"
    else
        echo "FAIL: $APPS recipes: $(recipe_set "$APPS" | tr '\n' ' ')" \
            "vs recorded $(tr '\n' ' ' <<< "$recorded")"
    fi

    shown=$(just --justfile "$MASTER" --show install-jetbrains-toolbox 2>&1 || true)
    if grep -q 'bazzite-mx-jetbrains-toolbox' <<< "$shown"; then
        echo "OK: ujust install-jetbrains-toolbox is our recipe"
    else
        echo "FAIL: ujust --show install-jetbrains-toolbox: $(head -n3 <<< "$shown" | tr '\n' ' ')"
    fi
}

# The two files that replace a base file hold the recipes the base's held.
check_replacing_files() {
    local file recorded

    for file in 84-bazzite-virt.just 82-bazzite-sunshine.just; do
        recorded=$(recorded_recipes_of "$file")

        if [ -n "$recorded" ] && [ "$(recipe_set "$JUST_DIR/$file")" = "$recorded" ] \
            && cmp -s "$CTX/system_files$JUST_DIR/$file" "$JUST_DIR/$file"; then
            echo "OK: $file is ours and holds what the base's held ($(tr '\n' ' ' <<< "$recorded"))"
        else
            echo "FAIL: $file: ours $(recipe_set "$JUST_DIR/$file" | tr '\n' ' ')" \
                "vs base $(tr '\n' ' ' <<< "$recorded")"
        fi
    done
}

check_format_and_help() {
    local file recipe

    for file in "$CTX"/system_files/usr/share/ublue-os/just/*.just; do
        check_just_fmt "$file"
    done

    for recipe in $OUR_RECIPES; do
        check_recipe_help "$MASTER" "$recipe"
    done
}

# --- the helpers behind the recipes -------------------------------------------

check_helper_files() {
    local helper

    for helper in bazzite-mx-verify-host bazzite-mx-migrate bazzite-mx-jetbrains-toolbox \
        bazzite-mx-ntfsplus-setup; do
        if [ -x "/usr/libexec/$helper" ] && [ "$(stat -c %a "/usr/libexec/$helper")" = 755 ] \
            && bash -n "/usr/libexec/$helper"; then
            echo "OK: /usr/libexec/$helper executable (755), parses"
        else
            echo "FAIL: /usr/libexec/$helper missing, wrong mode or does not parse"
        fi
    done
}

# check_self_test <label> <command>...: the command's --self-test exits 0 and
# ends with its `self-test ok` line.
check_self_test() {
    local label=$1
    shift
    local output status

    if output=$("$@" --self-test 2>&1); then
        status=0
    else
        status=$?
    fi

    if [ "$status" -eq 0 ] && grep -q '^self-test ok' <<< "$output"; then
        echo "OK: $label self-test: $(tail -n1 <<< "$output")"
    else
        echo "FAIL: $label self-test (exit $status): $(tail -n3 <<< "$output" | tr '\n' ' ')"
    fi
}

# --- verify-host on fixtures --------------------------------------------------

# fixture_migrated_host <dir> <image name>: a migrated MSI host on the signed
# transport, every check green; the file setup-msi writes is present and
# must not be read as residue.
fixture_migrated_host() {
    local fixture=$1
    local image=$2
    local booted_image="ghcr.io/matrixdj96/$image:stable"
    local origin="ostree-image-signed:docker://$booted_image"

    mkdir -p "$fixture/cmd" "$fixture/etc/containers/registries.d" "$fixture/etc/pki/containers" \
        "$fixture/etc/modprobe.d" "$fixture/etc/modules-load.d" "$fixture/usr/share/ublue-os" \
        "$fixture/sys/class/dmi/id" "$fixture/proc"

    cp "$IMAGE_INFO" "$fixture/usr/share/ublue-os/"
    cp /etc/containers/policy.json "$fixture/etc/containers/"
    cp /etc/containers/registries.d/matrixdj96.yaml "$fixture/etc/containers/registries.d/"
    cp /etc/pki/containers/matrixdj96.pub "$fixture/etc/pki/containers/"

    printf 'Micro-Star International Co., Ltd.\n' > "$fixture/sys/class/dmi/id/sys_vendor"
    printf 'msi_ec 16384 0 - Live 0x0\nacpi_ec 12288 0 - Live 0x0\nnvidia 1000 0 - Live 0x0\n' \
        > "$fixture/proc/modules"
    printf 'msi-ec\nacpi_ec\n' > "$fixture/etc/modules-load.d/bazzite-mx-msi.conf"
    printf 'UUID=1 / btrfs subvol=root 0 0\nUUID=2 /mnt/win ntfs3 defaults,nofail 0 0\n' \
        > "$fixture/etc/fstab"
    printf '/mnt/win ntfs3\n' > "$fixture/cmd/mounts"
    printf 'nodev\tbtrfs\n\tntfs3\n' > "$fixture/proc/filesystems"
    printf 'root=UUID=1 rw\n' > "$fixture/cmd/kargs"
    printf 'org.kde.okular\n' > "$fixture/cmd/flatpaks"

    if [[ $image == *nvidia* ]]; then
        printf '%s\n' "$NVIDIA_GPU_LINE" > "$fixture/cmd/lspci-nvidia"
    else
        : > "$fixture/cmd/lspci-nvidia"
    fi

    fixture_write_bootc_status "$fixture" false "{\"image\":{\"image\":\"$booted_image\"}}"
    fixture_write_rpm_ostree_status "$fixture" "$origin" '"packages":[],
        "requested-local-packages":[],"requested-base-removals":[],"requested-modules":null,
        "regenerate-initramfs":false' 44.20260903
}

# fixture_write_bootc_status <dir> <incompatible> <image json>
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

check_verify_host_on_migrated_fixture() {
    local fixture=$1
    local output ok_count

    run_verify_host "$fixture"
    output=$VERIFY_HOST_OUTPUT
    ok_count=$(grep -c '^OK:' <<< "$output")

    if [ "$VERIFY_HOST_STATUS" -eq 0 ] && ! grep -q '^FAIL:' <<< "$output" \
        && [ "$ok_count" -ge 14 ] \
        && grep -q '^OK: no modules-load file names msi-ec' <<< "$output"; then
        echo "OK: verify-host passes on the migrated fixture" \
            "($ok_count OK lines, setup-msi's file not residue)"
    else
        echo "FAIL: verify-host on the migrated fixture (exit $VERIFY_HOST_STATUS):" \
            "$(grep -E '^(FAIL|ERROR)' <<< "$output" | tr '\n' ' ')"
    fi
}

# Known-bad: a host before the migration, with every defect at once. Each
# one must be named on its own line.
check_verify_host_on_unmigrated_fixture() {
    local good=$1
    local image=$2
    local fixture=$good/../bad
    local origin="ostree-unverified-registry:ghcr.io/matrixdj96/$image:44.20260831"
    local expected_fails output matched

    cp -a "$good/." "$fixture/"
    fixture_write_bootc_status "$fixture" true null
    fixture_write_rpm_ostree_status "$fixture" "$origin" '"packages":[],
        "requested-packages":["1password"],"requested-local-packages":["teams-for-linux"],
        "regenerate-initramfs":true,"initramfs-args":["--hostonly"]' 44.20260831
    jq 'del(.transports.docker["ghcr.io/matrixdj96"])' "$good/etc/containers/policy.json" \
        > "$fixture/etc/containers/policy.json"
    printf 'UUID=2 /mnt/win ntfs defaults,nofail 0 0\n' > "$fixture/etc/fstab"
    printf 'nvidia 1000 0 - Live 0x0\n' > "$fixture/proc/modules"
    printf 'blacklist ntfsplus\n' > "$fixture/etc/modprobe.d/ntfsplus.conf"
    printf 'msi-ec\n' > "$fixture/etc/modules-load.d/msi-ec.conf"
    printf 'org.mozilla.firefox\n' > "$fixture/cmd/flatpaks"

    expected_fails='bootc status reports'
    expected_fails+='|origin is not ostree-image-signed'
    expected_fails+='|rpm-ostree mutations in the origin: 1password teams-for-linux'
    expected_fails+='|initramfs is regenerated locally'
    expected_fails+='|policy.json has no sigstoreSigned scope'
    expected_fails+='|MSI host: msi_ec not loaded'
    expected_fails+='|MSI host: acpi_ec not loaded'
    expected_fails+='|fstab: /mnt/win uses type ntfs without the ntfsplus opt-in'
    expected_fails+='|ntfsplus residue: /etc/modprobe.d/ntfsplus.conf'
    expected_fails+='|MSI residue: /etc/modules-load.d/msi-ec.conf'

    run_verify_host "$fixture"
    output=$VERIFY_HOST_OUTPUT
    matched=$(grep -E '^FAIL:' <<< "$output" | grep -cE "$expected_fails" || true)

    if [ "$VERIFY_HOST_STATUS" -eq 1 ] && [ "$matched" -eq 10 ] \
        && grep -q '^INFO: the Firefox Flatpak is still installed' <<< "$output"; then
        echo "OK: verify-host names every defect of the unmigrated fixture" \
            "(10 FAIL lines, exit 1, Firefox Flatpak reported)"
    else
        echo "FAIL: verify-host on the unmigrated fixture: exit $VERIFY_HOST_STATUS," \
            "$matched of 10 expected FAIL lines:" \
            "$(grep -E '^(FAIL|INFO|ERROR)' <<< "$output" | tr '\n' ' ')"
    fi
}

# Known-bad: a host on the signed transport with every remaining defect at
# once: another flavour's dated tag, a policy whose key is missing and whose
# default is not reject, registries.d without the attachments, an NVIDIA GPU
# with the module unloaded, an ntfs3 row not mounted and one mounted by
# FUSE, a kernel argument naming ntfsplus.
check_verify_host_on_signed_but_wrong_fixture() {
    local good=$1
    local image=$2
    local fixture=$good/../bad2
    local other=bazzite-mx-nvidia
    local origin policy_rewrite expected_fails output matched

    if [ "$image" = "$other" ]; then
        other=bazzite-mx
    fi
    origin="ostree-image-signed:docker://ghcr.io/matrixdj96/$other:44.20260831"
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
    printf 'UUID=1 / btrfs subvol=root 0 0\nUUID=2 /mnt/win ntfs3 defaults,nofail 0 0\n' \
        > "$fixture/etc/fstab"
    printf 'UUID=3 /mnt/data ntfs3 defaults,nofail 0 0\n' >> "$fixture/etc/fstab"
    printf '/mnt/data fuseblk\n' > "$fixture/cmd/mounts"
    printf 'root=UUID=1 rw module_blacklist=ntfsplus\n' > "$fixture/cmd/kargs"

    expected_fails="origin image $other but the booted image calls itself $image"
    expected_fails+='|origin tag is 44.20260831, not stable'
    expected_fails+='|policy.json: ghcr.io/matrixdj96 scope names key'
    expected_fails+=" '/etc/pki/containers/missing.pub', which is missing"
    expected_fails+='|policy.json: default is'
    expected_fails+='|registries.d/matrixdj96.yaml missing or without use-sigstore-attachments'
    expected_fails+='|nvidia module not loaded'
    expected_fails+='|fstab: /mnt/win is ntfs3 but not mounted'
    expected_fails+='|fstab: /mnt/data is ntfs3 in fstab but mounted as fuseblk'
    expected_fails+='|kernel arguments mention ntfsplus: module_blacklist=ntfsplus'

    run_verify_host "$fixture"
    output=$VERIFY_HOST_OUTPUT
    matched=$(grep -E '^FAIL:' <<< "$output" | grep -cE "$expected_fails" || true)

    if [ "$VERIFY_HOST_STATUS" -eq 1 ] && [ "$matched" -eq 9 ]; then
        echo "OK: verify-host names every defect of the signed-but-wrong fixture" \
            "(9 FAIL lines, exit 1)"
    else
        echo "FAIL: verify-host on the signed-but-wrong fixture: exit $VERIFY_HOST_STATUS," \
            "$matched of 9 expected FAIL lines:" \
            "$(grep -E '^(FAIL|ERROR)' <<< "$output" | tr '\n' ' ')"
    fi
}

# Opted into NTFSPLUS: rows on ntfs, mounted as ntfs, driver registered; the
# opt-in carries the text setup-ntfsplus writes, which names ntfsplus.
# Known-bad: a row left on ntfs3, and the driver not registered.
check_verify_host_on_optin_fixture() {
    local good=$1
    local fixture=$good/../optin
    local output

    cp -a "$good/." "$fixture/"
    (
        source /usr/lib/bazzite-mx/host.sh
        ntfsplus_optin_text
    ) > "$fixture/etc/modprobe.d/bazzite-mx-ntfsplus.conf"
    printf 'UUID=1 / btrfs subvol=root 0 0\nUUID=2 /mnt/win ntfs defaults,nofail 0 0\n' \
        > "$fixture/etc/fstab"
    printf '/mnt/win ntfs\n' > "$fixture/cmd/mounts"
    printf 'nodev\tbtrfs\n\tntfs3\n\tntfs\n' > "$fixture/proc/filesystems"

    run_verify_host "$fixture"
    output=$VERIFY_HOST_OUTPUT
    if [ "$VERIFY_HOST_STATUS" -eq 0 ] && ! grep -q '^FAIL:' <<< "$output" \
        && grep -q '^OK: ntfsplus opt-in active' <<< "$output" \
        && grep -q '^OK: fstab: /mnt/win is ntfs and mounted with ntfs' <<< "$output"; then
        echo "OK: verify-host passes on the ntfsplus opt-in fixture" \
            "(ntfs rows expected, opt-in file not residue)"
    else
        echo "FAIL: verify-host on the opt-in fixture (exit $VERIFY_HOST_STATUS):" \
            "$(grep -E '^(FAIL|ERROR)' <<< "$output" | tr '\n' ' ')"
    fi

    printf 'UUID=1 / btrfs subvol=root 0 0\nUUID=2 /mnt/win ntfs3 defaults,nofail 0 0\n' \
        > "$fixture/etc/fstab"
    printf 'nodev\tbtrfs\n\tntfs3\n' > "$fixture/proc/filesystems"

    run_verify_host "$fixture"
    output=$VERIFY_HOST_OUTPUT
    if grep -q '^FAIL: fstab: /mnt/win uses type ntfs3 while the ntfsplus opt-in is active' \
        <<< "$output" \
        && grep -q '^INFO: the ntfs driver is not registered yet' <<< "$output"; then
        echo "OK: verify-host names an ntfs3 row under the opt-in," \
            "reports an unloaded driver as INFO"
    else
        echo "FAIL: verify-host under the opt-in with an ntfs3 row:" \
            "$(grep -E '^(FAIL|OK).*ntfs' <<< "$output" | tr '\n' ' ')"
    fi
}

# A flavour that does not match the GPU is a defect in both directions.
check_verify_host_on_gpu_mismatch() {
    local good=$1
    local image=$2
    local fixture=$good/../gpu
    local expected output

    mkdir -p "$fixture"
    cp -a "$good/." "$fixture/"

    if [[ $image == *nvidia* ]]; then
        : > "$fixture/cmd/lspci-nvidia"
        expected='no NVIDIA GPU on the bus but the image is'
    else
        printf '%s\n' "$NVIDIA_GPU_LINE" > "$fixture/cmd/lspci-nvidia"
        expected='NVIDIA GPU present but the image is'
    fi

    run_verify_host "$fixture"
    output=$VERIFY_HOST_OUTPUT
    if grep -q "^FAIL: $expected" <<< "$output"; then
        echo "OK: verify-host refuses a flavour that does not match the GPU"
    else
        echo "FAIL: verify-host GPU/flavour check:" \
            "$(grep -E '^(FAIL|OK).*(GPU|nvidia)' <<< "$output" | tr '\n' ' ')"
    fi
}

# --- the Toolbox installer on a file:// feed ----------------------------------

# fixture_toolbox_tree <dir>: the unpacked layout upstream ships, build 9.9.9.
fixture_toolbox_tree() {
    local dir=$1
    local bin=$dir/jetbrains-toolbox-9.9.9/bin

    rm -rf "$dir/jetbrains-toolbox-9.9.9"
    mkdir -p "$bin"
    printf '#!/bin/sh\necho toolbox\n' > "$bin/jetbrains-toolbox"
    chmod 755 "$bin/jetbrains-toolbox"
    printf '9.9.9\n' > "$bin/build.txt"
}

# fixture_toolbox_pack <dir> [<top directory>]: the tarball and the checksum
# file good.sha256 that matches it.
fixture_toolbox_pack() {
    local dir=$1
    local top=${2:-jetbrains-toolbox-9.9.9}
    local checksum

    tar czf "$dir/jetbrains-toolbox-9.9.9.tar.gz" -C "$dir" "$top"
    checksum=$(sha256sum "$dir/jetbrains-toolbox-9.9.9.tar.gz" | cut -d' ' -f1)
    printf '%s *jetbrains-toolbox-9.9.9.tar.gz\n' "$checksum" > "$dir/good.sha256"
}

# fixture_toolbox_feed <dir> <feed file> <build> [<checksum file>]: the
# release feed in upstream's shape, without the checksum link when no
# checksum file is given.
fixture_toolbox_feed() {
    local dir=$1
    local feed=$2
    local build=$3
    local checksum_file=${4:-}
    local link="file://$dir/jetbrains-toolbox-9.9.9.tar.gz"
    local downloads="\"link\":\"$link\""

    if [ -n "$checksum_file" ]; then
        downloads+=",\"checksumLink\":\"file://$dir/$checksum_file\""
    fi

    printf '{"TBA":[{"build":"%s","downloads":{"linux":{%s}}}]}\n' "$build" "$downloads" \
        > "$dir/$feed"
}

# run_toolbox <dir> <feed file> <command>: the installer against the feed,
# with the fixture home and the file:// protocol allowed.
run_toolbox() {
    local dir=$1
    local feed=$2
    local command=$3

    HOME=$dir/home XDG_DATA_HOME='' XDG_CACHE_HOME='' NO_LAUNCH=1 CURL_PROTO='=https,file' \
        FEED_URL="file://$dir/$feed" "$TOOLBOX" "$command"
}

toolbox_reset_home() {
    local dir=$1

    rm -rf "$dir/home/.local" "$dir/home/.cache"
}

check_toolbox_install() {
    local dir=$1
    local app=$dir/home/.local/share/JetBrains/ToolboxApp
    local download=$dir/home/.cache/bazzite-mx/jetbrains-toolbox/jetbrains-toolbox-9.9.9.tar.gz
    local output

    output=$(run_toolbox "$dir" feed-good.json latest 2>&1 || true)
    if grep -q '^build 9.9.9$' <<< "$output"; then
        echo "OK: toolbox latest reads the feed"
    else
        echo "FAIL: toolbox latest: $(head -n2 <<< "$output" | tr '\n' ' ')"
    fi

    if output=$(run_toolbox "$dir" feed-wrong.json install 2>&1); then
        echo "FAIL: toolbox installer accepted a wrong sha256"
    elif grep -q 'sha256 mismatch' <<< "$output" && [ ! -e "$app" ] && [ ! -e "$download" ]; then
        echo "OK: toolbox installer refuses a wrong sha256, installs nothing, drops the download"
    else
        echo "FAIL: toolbox installer on a wrong sha256: $(tail -n1 <<< "$output");" \
            "$(find "$dir/home" -type f | tr '\n' ' ')"
    fi

    if output=$(run_toolbox "$dir" feed-good.json install 2>&1) \
        && [ -x "$app/bin/jetbrains-toolbox" ] && [ "$(cat "$app/bin/build.txt")" = 9.9.9 ]; then
        echo "OK: toolbox installer unpacks the verified build ($(tail -n1 <<< "$output"))"
    else
        echo "FAIL: toolbox installer on the good feed: $(tail -n2 <<< "$output" | tr '\n' ' ')"
    fi

    output=$(run_toolbox "$dir" feed-good.json status 2>&1 || true)
    if grep -q '^installed: build 9.9.9 at ' <<< "$output"; then
        echo "OK: toolbox status reports the installed build"
    else
        echo "FAIL: toolbox status: $(head -n1 <<< "$output")"
    fi

    output=$(run_toolbox "$dir" feed-good.json install 2>&1 || true)
    if grep -q 'already installed' <<< "$output"; then
        echo "OK: toolbox installer is idempotent on the same build"
    else
        echo "FAIL: toolbox second install: $(tail -n1 <<< "$output")"
    fi
}

# A Toolbox unpacked at the same path by something else (an earlier recipe,
# a hand install) carries upstream's bin/build.txt and nothing of ours:
# status reports it and install leaves it alone.
check_toolbox_foreign_install() {
    local dir=$1
    local app=$dir/home/.local/share/JetBrains/ToolboxApp
    local download=$dir/home/.cache/bazzite-mx/jetbrains-toolbox/jetbrains-toolbox-9.9.9.tar.gz
    local output

    toolbox_reset_home "$dir"
    mkdir -p "$app"
    cp -a "$dir/jetbrains-toolbox-9.9.9/bin" "$app/"

    output=$(run_toolbox "$dir" feed-good.json status 2>&1 || true)
    if grep -q '^installed: build 9.9.9 at ' <<< "$output"; then
        echo "OK: toolbox status reads the build of a Toolbox it did not unpack (bin/build.txt)"
    else
        echo "FAIL: toolbox status on a foreign Toolbox: $(head -n1 <<< "$output")"
    fi

    output=$(run_toolbox "$dir" feed-good.json install 2>&1 || true)
    if grep -q 'already installed' <<< "$output" && [ ! -e "$download" ]; then
        echo "OK: toolbox installer leaves a foreign Toolbox of the same build alone"
    else
        echo "FAIL: toolbox install over a foreign Toolbox of the same build:" \
            "$(tail -n1 <<< "$output")"
    fi
}

# check_toolbox_refuses <dir> <feed file> <message> <what>: the install is
# refused with the message and nothing lands under the home.
check_toolbox_refuses() {
    local dir=$1
    local feed=$2
    local message=$3
    local what=$4
    local app=$dir/home/.local/share/JetBrains/ToolboxApp
    local output

    toolbox_reset_home "$dir"

    if output=$(run_toolbox "$dir" "$feed" install 2>&1); then
        echo "FAIL: toolbox installer accepted $what"
    elif grep -q "$message" <<< "$output" && [ ! -e "$app" ]; then
        echo "OK: toolbox installer refuses $what"
    else
        echo "FAIL: toolbox installer on $what: $(tail -n1 <<< "$output")"
    fi
}

# Known-bad tarballs, first pair: upstream's bin/build.txt missing, the
# binary missing.
check_toolbox_refuses_broken_contents() {
    local dir=$1

    fixture_toolbox_tree "$dir"
    rm -f "$dir/jetbrains-toolbox-9.9.9/bin/build.txt"
    fixture_toolbox_pack "$dir"
    check_toolbox_refuses "$dir" feed-good.json 'bin/build.txt missing' \
        'a tarball without bin/build.txt'

    fixture_toolbox_tree "$dir"
    rm -rf "$dir/jetbrains-toolbox-9.9.9/bin"
    mkdir -p "$dir/jetbrains-toolbox-9.9.9/lib"
    fixture_toolbox_pack "$dir"
    check_toolbox_refuses "$dir" feed-good.json 'bin/jetbrains-toolbox missing' \
        'a tarball without bin/jetbrains-toolbox'
}

# Known-bad tarballs, second pair: another top directory, a binary without
# the execute bit.
check_toolbox_refuses_bad_shapes() {
    local dir=$1

    fixture_toolbox_tree "$dir"
    mv "$dir/jetbrains-toolbox-9.9.9" "$dir/toolbox-9.9.9"
    fixture_toolbox_pack "$dir" toolbox-9.9.9
    mv "$dir/toolbox-9.9.9" "$dir/jetbrains-toolbox-9.9.9"
    check_toolbox_refuses "$dir" feed-good.json 'unexpected top directory' \
        'a tarball with another top directory'

    fixture_toolbox_tree "$dir"
    chmod 644 "$dir/jetbrains-toolbox-9.9.9/bin/jetbrains-toolbox"
    fixture_toolbox_pack "$dir"
    check_toolbox_refuses "$dir" feed-good.json 'is not executable' \
        'a tarball whose binary is not executable'
}

# Known-bad feeds: no checksum link, a link naming another build, a checksum
# file that is not a sha256.
check_toolbox_refuses_bad_feeds() {
    local dir=$1

    fixture_toolbox_tree "$dir"
    fixture_toolbox_pack "$dir"
    printf 'not a checksum\n' > "$dir/garbage.sha256"
    fixture_toolbox_feed "$dir" feed-noshape.json 9.9.9
    fixture_toolbox_feed "$dir" feed-otherbuild.json 9.9.8 good.sha256
    fixture_toolbox_feed "$dir" feed-garbage.json 9.9.9 garbage.sha256

    check_toolbox_refuses "$dir" feed-noshape.json 'the feed lost its shape' \
        'a feed without the checksum link'
    check_toolbox_refuses "$dir" feed-otherbuild.json 'does not name build 9.9.8' \
        'a link that names another build'
    check_toolbox_refuses "$dir" feed-garbage.json 'does not start with a sha256' \
        'a checksum file that is not a sha256'
}

# --- setup-dev ----------------------------------------------------------------

check_setup_dev_inputs() {
    if [ -x /usr/bin/mise ] && [ -s /etc/skel/.config/mise/config.toml ]; then
        echo "OK: mise and the skel config setup-dev seeds are in the image"
    else
        echo "FAIL: /usr/bin/mise or /etc/skel/.config/mise/config.toml missing"
    fi
}

# --- main ---------------------------------------------------------------------

check_our_recipe_file
check_master_justfile
check_base_recipe_cut_out
check_replacing_files
check_format_and_help

check_helper_files
check_self_test migrate /usr/libexec/bazzite-mx-migrate
check_self_test 70-justfile.sh bash "$CTX/build_files/70-justfile.sh"

work=$(mktemp -d)
image=$(jq -r '."image-name"' "$IMAGE_INFO")
fixture_migrated_host "$work/ok" "$image"
check_verify_host_on_migrated_fixture "$work/ok"
check_verify_host_on_unmigrated_fixture "$work/ok" "$image"
check_verify_host_on_signed_but_wrong_fixture "$work/ok" "$image"
check_verify_host_on_optin_fixture "$work/ok"
check_verify_host_on_gpu_mismatch "$work/ok" "$image"

toolbox=$work/toolbox
mkdir -p "$toolbox/home"
fixture_toolbox_tree "$toolbox"
fixture_toolbox_pack "$toolbox"
printf '%064d *jetbrains-toolbox-9.9.9.tar.gz\n' 0 > "$toolbox/wrong.sha256"
fixture_toolbox_feed "$toolbox" feed-good.json 9.9.9 good.sha256
fixture_toolbox_feed "$toolbox" feed-wrong.json 9.9.9 wrong.sha256
check_toolbox_install "$toolbox"
check_toolbox_foreign_install "$toolbox"
check_toolbox_refuses_broken_contents "$toolbox"
check_toolbox_refuses_bad_feeds "$toolbox"
check_toolbox_refuses_bad_shapes "$toolbox"
rm -rf "$work"

check_setup_dev_inputs
