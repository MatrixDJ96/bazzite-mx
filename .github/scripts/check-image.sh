#!/usr/bin/env bash
# Probes the image that will ship, on the artefact itself: the labels the build
# stamped, /run and /tmp empty, bootc's own lint, the probe packages, the
# out-of-tree kernel modules for the image's kernel, the ntfsplus opt-in and
# image-info.json.
#
# The in-build smoke tests see the tree before the rechunk and never the labels;
# this sees what a host would pull. The probe holds image-info.json's image-name
# and image-ref against the title label, so a host cannot be sent to another
# flavour's repository by a file the build wrote wrong. The two sides still
# descend from one resolve-base.sh run, so a build that resolved the wrong
# flavour to begin with passes: what this catches is 10-image-info.sh, not the
# resolution.
#
# Usage: check-image.sh <image> <labels-file>
#          <image>        a reference in the local containers-storage
#          <labels-file>  the image-labels.sh KEY=value lines the build stamped
#        check-image.sh --self-test
# Output: `labels ok: N labels match`, `run and tmp ok: empty in the image`, the
#   probe's own lines, then `check-image ok: <image>`. The first refusal is a
#   `check-image: …` line on stderr, the leftovers under /run and /tmp listed
#   below it.
# Exit status: 0 the image passes every check; 1 on the first check failed or a
#   bad argument; podman's own status when the image is not known.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# Packages whose presence proves three of the five vendored repositories were
# installed.
PROBE_PACKAGES="docker-ce code 1password"

# --- the labels ---------------------------------------------------------------

# check_labels <labels json> <labels file>: every KEY=value line of the file
# carried by the image with that value. Status 1 on the first mismatch or an
# empty file, so the self-test can call it under `if`.
check_labels() {
    local labels_json=$1
    local file=$2
    local line key stamped carried
    local matched=0

    while IFS= read -r line; do
        key=${line%%=*}
        stamped=${line#*=}
        carried=$(jq -r --arg key "$key" '.[$key] // empty' <<< "$labels_json")

        if [ "$carried" != "$stamped" ]; then
            print_error "label $key: image has '$carried', build stamped '$stamped'"
            return 1
        fi

        matched=$((matched + 1))
    done < "$file"

    if [ "$matched" -eq 0 ]; then
        print_error "no labels in $file"
        return 1
    fi

    echo "labels ok: $matched labels match"
}

# --- the runtime probe --------------------------------------------------------
#
# A script run inside the image with bash -c. KVER, VERSION and TITLE come from
# the labels: the image has to agree with what it was stamped with. Every failed
# check prints its reason and exits 1.

PROBE=$(
    cat << 'EOF'
set -euo pipefail

echo "== bootc container lint"
bootc container lint --fatal-warnings --no-truncate

echo "== packages"
rpm -q $PROBE_PACKAGES

echo "== kernel modules for $KVER"
for ko in msi-ec acpi_ec ntfs; do
    file=/usr/lib/modules/$KVER/updates/$ko.ko

    if [ ! -f "$file" ]; then
        echo "$file missing"
        exit 1
    fi

    if ! vermagic=$(modinfo -F vermagic "$file" 2>&1); then
        echo "$ko: modinfo cannot read $file: $vermagic"
        exit 1
    fi

    if [[ "$vermagic" != "$KVER "* ]]; then
        echo "$ko vermagic '$vermagic' is not for $KVER"
        exit 1
    fi

    if ! resolved=$(modinfo -k "$KVER" -F filename "$ko" 2>&1); then
        echo "$ko: modprobe does not resolve it for $KVER: $resolved"
        exit 1
    fi

    resolved=$(realpath "$resolved")

    if [ "$resolved" != "$file" ]; then
        echo "modprobe $ko resolves to $resolved, not $file"
        exit 1
    fi

    echo "$ko: $file, vermagic $KVER"
done

# The ntfsplus opt-in (55-ntfsplus.sh): the type stays blacklisted and no
# generic mount.ntfs helper survives to hijack it.
if [ ! -f /usr/lib/modprobe.d/bazzite-mx-ntfsplus.conf ]; then
    echo "bazzite-mx-ntfsplus.conf missing"
    exit 1
fi

blacklist=$(grep -vE '^\s*(#|$)' /usr/lib/modprobe.d/bazzite-mx-ntfsplus.conf || true)

if [ "$blacklist" != "blacklist ntfs" ]; then
    echo "bazzite-mx-ntfsplus.conf is not 'blacklist ntfs'"
    exit 1
fi

for helper in /usr/bin/mount.ntfs /usr/bin/mount.ntfs-fuse; do
    if [ -e "$helper" ] || [ -L "$helper" ]; then
        echo "$helper still present"
        exit 1
    fi
done

echo "ntfs: blacklisted, mount.ntfs helpers gone"

echo "== image-info.json"
info_json=/usr/share/ublue-os/image-info.json

if ! info_version=$(jq -r '.version // empty' "$info_json" 2> /dev/null); then
    echo "image-info.json missing or not JSON"
    exit 1
fi

if [ "$info_version" != "$VERSION" ]; then
    echo "image-info.json version '$info_version', label '$VERSION'"
    exit 1
fi

info_name=$(jq -r '."image-name" // empty' "$info_json")
info_ref=$(jq -r '."image-ref" // empty' "$info_json")

if [ -z "$info_name" ] || [ -z "$info_ref" ]; then
    echo "image-info.json has no image-name or image-ref"
    exit 1
fi

if [ "$info_name" != "$TITLE" ]; then
    echo "image-info.json image-name '$info_name', label title '$TITLE'"
    exit 1
fi

if [ "${info_ref##*/}" != "$TITLE" ]; then
    echo "image-info.json image-ref '$info_ref' does not end in '$TITLE'"
    exit 1
fi

echo "version $VERSION, image-name and image-ref name $TITLE"
EOF
)

# --- the image ----------------------------------------------------------------

# check_run_and_tmp_empty <image>: nothing under /run or /tmp in the image, or
# exit 1. Read on the mounted image: podman populates /run inside a container,
# where bootc's own lint cannot see the difference. The inner shell keeps find's
# status and unmounts on both paths, so a directory it cannot read is a refusal
# with a reason and never leaves the image mounted on the host.
check_run_and_tmp_empty() {
    local image=$1
    local leftovers

    if ! leftovers=$(podman unshare bash -euo pipefail -c '
        mnt=$(podman image mount "$1")

        if find "$mnt/run" "$mnt/tmp" -mindepth 1 | sed "s|^$mnt||"; then
            status=0
        else
            status=$?
        fi

        podman image umount "$1" > /dev/null
        exit $status' _ "$image" 2>&1); then
        exit_with_error "cannot read /run and /tmp of $image: ${leftovers//$'\n'/ }"
    fi

    if [ -n "$leftovers" ]; then
        echo "check-image: /run or /tmp not empty in the image:" >&2
        sed 's/^/  /' <<< "$leftovers" >&2
        exit 1
    fi

    echo "run and tmp ok: empty in the image"
}

# run_probe <image> <kernel> <version> <title>: PROBE inside the image, offline,
# with /run and /tmp as tmpfs so the image's own are left as they are; exits 1
# when the probe fails.
run_probe() {
    local image=$1
    local kernel=$2
    local version=$3
    local title=$4

    if ! podman run --rm --tmpfs /run --tmpfs /tmp --network=none \
        --env "KVER=$kernel" --env "VERSION=$version" --env "TITLE=$title" \
        --env "PROBE_PACKAGES=$PROBE_PACKAGES" \
        "$image" bash -c "$PROBE"; then
        exit_with_error "runtime probe failed on $image"
    fi
}

# check_image <image> <labels file>: the labels, the empty /run and /tmp, then
# the probe; stops at the first failure.
check_image() {
    local image=$1
    local file=$2
    local labels_json kernel version title

    labels_json=$(podman image inspect --format '{{json .Labels}}' "$image")

    if ! check_labels "$labels_json" "$file"; then
        exit 1
    fi

    kernel=$(sed -n 's/^ostree\.linux=//p' "$file")
    version=$(sed -n 's/^org\.opencontainers\.image\.version=//p' "$file")
    title=$(sed -n 's/^org\.opencontainers\.image\.title=//p' "$file")

    check_run_and_tmp_empty "$image"
    run_probe "$image" "$kernel" "$version" "$title"

    echo "check-image ok: $image"
}

# --- self-test ----------------------------------------------------------------

# self_test_write_labels <file>: four stamped labels, a subset of what an image
# carries.
self_test_write_labels() {
    local file=$1

    printf '%s\n' \
        "org.opencontainers.image.title=bazzite-mx" \
        "org.opencontainers.image.version=44.20260902.dev" \
        "ostree.linux=7.2.1-ogc4.1.fc44.x86_64" \
        "containers.bootc=1" > "$file"
}

# self_test_check_labels <dir>: a missing label, a changed label and an empty
# labels file refused.
self_test_check_labels() {
    local dir=$1
    local good=$dir/labels.txt
    local labels_json changed

    self_test_write_labels "$good"
    labels_json=$(
        cat << 'EOF'
{"org.opencontainers.image.title":"bazzite-mx",
 "org.opencontainers.image.version":"44.20260902.dev",
 "ostree.linux":"7.2.1-ogc4.1.fc44.x86_64",
 "containers.bootc":"1"}
EOF
    )

    REFUSED=$((REFUSED + 1))
    changed=$(jq -c 'del(."ostree.linux")' <<< "$labels_json")

    if check_labels "$changed" "$good" > /dev/null 2>&1; then
        fail_self_test "missing label accepted"
    fi

    REFUSED=$((REFUSED + 1))
    changed=$(jq -c '."org.opencontainers.image.version" = "44.20260902"' <<< "$labels_json")

    if check_labels "$changed" "$good" > /dev/null 2>&1; then
        fail_self_test "changed label accepted"
    fi

    REFUSED=$((REFUSED + 1))
    : > "$dir/empty.txt"

    if check_labels "$labels_json" "$dir/empty.txt" > /dev/null 2>&1; then
        fail_self_test "empty labels file accepted"
    fi
}

# self_test_run_and_tmp <dir>: on a podman stubbed on PATH, check_image on a
# tree with both directories empty, each of its three checks' lines in its
# output and the image unmounted; check_image stopping on an image without the
# stamped labels and on a probe that fails; then the probe over one with a file
# left under each and one missing both. Known-bad: find's failure ended the
# inner shell before the unmount and the outer assignment died under set -e, so
# the probe left the image mounted and printed find's line with no verdict of
# its own.
self_test_run_and_tmp() {
    local dir=$1
    local output labels line

    mkdir -p "$dir/bin" "$dir/image/run" "$dir/image/tmp"
    cat > "$dir/bin/podman" << 'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "unshare bash")
        shift
        exec "$@"
        ;;
    "image mount")
        echo "$STUB_IMAGE_TREE"
        ;;
    "image umount")
        echo umounted >> "$STUB_UMOUNT_LOG"
        ;;
    "image inspect")
        echo "$STUB_LABELS"
        ;;
    "run --rm")
        echo "probe ran"
        exit "${STUB_PROBE_STATUS:-0}"
        ;;
    *)
        echo "podman stub: unexpected $*" >&2
        exit 2
        ;;
esac
EOF
    chmod +x "$dir/bin/podman"
    export STUB_IMAGE_TREE=$dir/image STUB_UMOUNT_LOG=$dir/umount.log
    : > "$STUB_UMOUNT_LOG"

    labels='{"org.opencontainers.image.title":"bazzite-mx",'
    labels+='"org.opencontainers.image.version":"44.20260902.dev",'
    labels+='"ostree.linux":"7.2.1-ogc4.1.fc44.x86_64","containers.bootc":"1",'
    labels+='"io.buildah.version":"1.43.2"}'
    if ! output=$(PATH="$dir/bin:$PATH" STUB_LABELS=$labels \
        check_image stub:latest "$dir/labels.txt" 2>&1); then
        fail_self_test "check_image refused the good image: ${output//$'\n'/ }"
    fi

    for line in "labels ok: 4 labels match" "run and tmp ok" "probe ran"; do
        if ! grep -q "^$line" <<< "$output"; then
            fail_self_test "check_image ran without '$line': ${output//$'\n'/ }"
        fi
    done

    if [ ! -s "$STUB_UMOUNT_LOG" ]; then
        fail_self_test "the probe left the image mounted"
    fi

    REFUSED=$((REFUSED + 1))

    if output=$(PATH="$dir/bin:$PATH" STUB_LABELS='{}' \
        check_image stub:latest "$dir/labels.txt" 2>&1); then
        fail_self_test "check_image passed an image without the stamped labels"
    fi

    REFUSED=$((REFUSED + 1))

    if output=$(PATH="$dir/bin:$PATH" STUB_LABELS=$labels STUB_PROBE_STATUS=1 \
        check_image stub:latest "$dir/labels.txt" 2>&1); then
        fail_self_test "check_image passed an image whose probe failed"
    fi

    touch "$dir/image/run/leftover" "$dir/image/tmp/leftover"
    REFUSED=$((REFUSED + 1))

    if output=$(PATH="$dir/bin:$PATH" check_run_and_tmp_empty stub:latest 2>&1); then
        fail_self_test "an image with a file under /run passed"
    fi

    if ! grep -qx '  /run/leftover' <<< "$output" \
        || ! grep -qx '  /tmp/leftover' <<< "$output"; then
        fail_self_test "the files left under /run and /tmp not listed: ${output//$'\n'/ }"
    fi

    rm "$dir/image/run/leftover" "$dir/image/tmp/leftover"
    rmdir "$dir/image/run" "$dir/image/tmp"
    : > "$STUB_UMOUNT_LOG"
    REFUSED=$((REFUSED + 1))

    if output=$(PATH="$dir/bin:$PATH" check_run_and_tmp_empty stub:latest 2>&1); then
        fail_self_test "an image the probe cannot read passed"
    fi

    if [ "$(grep -c '' <<< "$output")" -ne 1 ] \
        || ! grep -q "^$SCRIPT_NAME: cannot read /run and /tmp of stub:latest: " <<< "$output"; then
        fail_self_test "a probe that cannot read not folded into one line:" \
            "${output//$'\n'/ }"
    fi

    if [ ! -s "$STUB_UMOUNT_LOG" ]; then
        fail_self_test "the failed probe left the image mounted"
    fi

    unset STUB_IMAGE_TREE STUB_UMOUNT_LOG
}

self_test() {
    local dir

    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN

    self_test_check_labels "$dir"
    self_test_run_and_tmp "$dir"

    echo "self-test ok: 1 matching label set accepted, 1 image checked whole," \
        "$REFUSED bad inputs refused"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    "" | -*)
        exit_with_error "usage: check-image.sh <image> <labels-file> | --self-test"
        ;;
    *)
        if [ $# -ne 2 ]; then
            exit_with_error "usage: check-image.sh <image> <labels-file>"
        fi

        check_image "$1" "$2"
        ;;
esac
