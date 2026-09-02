#!/usr/bin/env bash
# The probe of the image that will ship, run on the artefact itself: the
# labels the build stamped, /run and /tmp empty, bootc's own lint, the probe
# packages, the out-of-tree kernel modules for the image's kernel, the
# ntfsplus opt-in and image-info.json. The in-build smoke tests see the tree
# before the rechunk and never the labels; this sees what a host would pull.
#
# Usage: check-image.sh <image> <labels-file>
#          <image>        a reference in the local containers-storage
#          <labels-file>  the KEY=value lines of image-labels.sh the build stamped
#        check-image.sh --self-test
# Output: `labels ok: N labels match`, `run and tmp ok: empty in the image`,
#   the probe's own lines, then `check-image ok: <image>`. A mismatch is one
#   `check-image: …` line on stderr.
# Exit status: 0 the image passes every check; 1 on the first check failed
#   or a bad argument; podman's own status when the image is not known.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# Packages whose presence proves the vendored repositories were installed.
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
        if [ -z "$line" ]; then
            continue
        fi

        key=${line%%=*}
        stamped=${line#*=}
        carried=$(jq -r --arg key "$key" '.[$key] // empty' <<< "$labels_json")
        if [ "$carried" != "$stamped" ]; then
            echo "check-image: label $key: image has '$carried', build stamped '$stamped'" >&2
            return 1
        fi

        matched=$((matched + 1))
    done < "$file"

    if [ "$matched" -eq 0 ]; then
        echo "check-image: no labels in $file" >&2
        return 1
    fi

    echo "labels ok: $matched labels match"
}

# --- the runtime probe --------------------------------------------------------
#
# A script run inside the image with bash -c. KVER and VERSION come from the
# labels: the image has to agree with what it was stamped with. Every failed
# check prints its reason and exits 1.

PROBE=$(
    cat << 'EOF'
set -euo pipefail

echo "== bootc container lint"
bootc container lint --fatal-warnings --no-truncate

echo "== packages"
rpm -q $PROBE_PACKAGES

echo "== kernel modules for $KVER"
if [ ! -d "/usr/lib/modules/$KVER" ]; then
    echo "no /usr/lib/modules/$KVER"
    exit 1
fi
for ko in msi-ec acpi_ec ntfs; do
    file=/usr/lib/modules/$KVER/updates/$ko.ko
    if [ ! -f "$file" ]; then
        echo "$file missing"
        exit 1
    fi

    vermagic=$(modinfo -F vermagic "$file")
    if [[ "$vermagic" != "$KVER "* ]]; then
        echo "$ko vermagic '$vermagic' is not for $KVER"
        exit 1
    fi

    resolved=$(realpath "$(modinfo -k "$KVER" -F filename "$ko")")
    if [ "$resolved" != "$file" ]; then
        echo "modprobe $ko resolves to $resolved, not $file"
        exit 1
    fi

    echo "$ko: $file, vermagic $KVER"
done

# The ntfsplus opt-in (55-ntfsplus.sh): the type stays blacklisted and no
# generic mount.ntfs helper survives to hijack it.
blacklist=$(grep -vE '^\s*(#|$)' /usr/lib/modprobe.d/bazzite-mx-ntfsplus.conf)
if [ "$blacklist" != "blacklist ntfs" ]; then
    echo "bazzite-mx-ntfsplus.conf is not 'blacklist ntfs'"
    exit 1
fi
for helper in /usr/bin/mount.ntfs /usr/sbin/mount.ntfs; do
    if [ -e "$helper" ] || [ -L "$helper" ]; then
        echo "$helper still present"
        exit 1
    fi
done
echo "ntfs: blacklisted, mount.ntfs helpers gone"

echo "== image-info.json"
info_version=$(jq -r '.version // empty' /usr/share/ublue-os/image-info.json)
if [ "$info_version" != "$VERSION" ]; then
    echo "image-info.json version '$info_version', label '$VERSION'"
    exit 1
fi
echo "version $VERSION"
EOF
)

# --- the image ----------------------------------------------------------------

# check_run_and_tmp_empty <image>: nothing under /run or /tmp in the image.
# Read on the mounted image: podman populates /run inside a container, where
# bootc's own lint cannot see the difference.
check_run_and_tmp_empty() {
    local image=$1
    local leftovers

    leftovers=$(podman unshare bash -euo pipefail -c '
        mnt=$(podman image mount "$1")
        find "$mnt/run" "$mnt/tmp" -mindepth 1 | sed "s|^$mnt||"
        podman image umount "$1" > /dev/null' _ "$image")

    if [ -n "$leftovers" ]; then
        echo "check-image: /run or /tmp not empty in the image:" >&2
        printf '  %s\n' "$leftovers" >&2
        exit 1
    fi

    echo "run and tmp ok: empty in the image"
}

# run_probe <image> <kernel> <version>: PROBE inside the image, offline, with
# /run and /tmp as tmpfs so the image's own are left as they are.
run_probe() {
    local image=$1
    local kernel=$2
    local version=$3

    if ! podman run --rm --tmpfs /run --tmpfs /tmp --network=none \
        --env "KVER=$kernel" --env "VERSION=$version" --env "PROBE_PACKAGES=$PROBE_PACKAGES" \
        "$image" bash -c "$PROBE"; then
        exit_with_error "runtime probe failed on $image"
    fi
}

# check_image <image> <labels file>: the labels, the empty /run and /tmp,
# then the probe; stops at the first failure.
check_image() {
    local image=$1
    local file=$2
    local labels_json kernel version

    labels_json=$(podman image inspect --format '{{json .Labels}}' "$image")
    if ! check_labels "$labels_json" "$file"; then
        exit 1
    fi

    kernel=$(sed -n 's/^ostree\.linux=//p' "$file")
    version=$(sed -n 's/^org\.opencontainers\.image\.version=//p' "$file")
    if [ -z "$kernel" ] || [ -z "$version" ]; then
        exit_with_error "$file has no ostree.linux or version label"
    fi

    check_run_and_tmp_empty "$image"
    run_probe "$image" "$kernel" "$version"

    echo "check-image ok: $image"
}

# --- self-test ----------------------------------------------------------------

# self_test_write_labels <file>: four stamped labels, a subset of what an
# image carries.
self_test_write_labels() {
    local file=$1

    printf '%s\n' \
        "org.opencontainers.image.title=bazzite-mx" \
        "org.opencontainers.image.version=44.20260902.dev" \
        "ostree.linux=7.2.1-ogc4.1.fc44.x86_64" \
        "containers.bootc=1" > "$file"
}

# self_test_check_labels <dir>: the stamped labels accepted against an image
# carrying them and one more; a missing label, a changed label, the base's
# title and an empty labels file refused.
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
 "containers.bootc":"1",
 "io.buildah.version":"1.43.2"}
EOF
    )
    if ! check_labels "$labels_json" "$good" > /dev/null; then
        fail_self_test "matching labels refused"
    fi

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
    changed=$(jq -c '."org.opencontainers.image.title" = "Bazzite"' <<< "$labels_json")
    if check_labels "$changed" "$good" > /dev/null 2>&1; then
        fail_self_test "the base's title accepted"
    fi

    REFUSED=$((REFUSED + 1))
    : > "$dir/empty.txt"
    if check_labels "$labels_json" "$dir/empty.txt" > /dev/null 2>&1; then
        fail_self_test "empty labels file accepted"
    fi
}

self_test() {
    local dir

    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN

    self_test_check_labels "$dir"

    echo "self-test ok: 1 matching label set accepted, $REFUSED bad inputs refused"
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
        if [ ! -f "$2" ]; then
            exit_with_error "labels file '$2' missing"
        fi
        check_image "$1" "$2"
        ;;
esac
