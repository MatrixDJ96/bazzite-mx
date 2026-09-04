#!/usr/bin/env bash
# Probe of the image that will ship, run on the artefact itself. The in-build
# smoke tests see the tree before the rechunk and never the labels; this sees
# what a host would pull.
#
#   check-image.sh <image> <labels-file>
#       image:       a reference in the local containers-storage
#       labels-file: the KEY=value lines of image-labels.sh the build stamped
#   check-image.sh --self-test
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

PROBE_PACKAGES="docker-ce code 1password"

# Returns 1 on the first mismatch, so the self-test can call it under `if`.
check_labels() {
    local json=$1 file=$2 line key want got n=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        key=${line%%=*}
        want=${line#*=}
        got=$(jq -r --arg k "$key" '.[$k] // empty' <<< "$json")
        if [ "$got" != "$want" ]; then
            echo "check-image: label $key: image has '$got', build stamped '$want'" >&2
            return 1
        fi
        n=$((n + 1))
    done < "$file"
    [ "$n" -gt 0 ] || {
        echo "check-image: no labels in $file" >&2
        return 1
    }
    echo "labels ok: $n labels match"
}

# Run inside the image. KVER and VERSION come from the labels: the image has
# to agree with what it was stamped with.
read -r -d '' PROBE << 'EOF' || true
set -euo pipefail
echo "== bootc container lint"
bootc container lint --fatal-warnings --no-truncate
echo "== packages"
rpm -q $PROBE_PACKAGES
echo "== kernel modules for $KVER"
[ -d "/usr/lib/modules/$KVER" ] || { echo "no /usr/lib/modules/$KVER"; exit 1; }
for ko in msi-ec acpi_ec ntfs; do
    file=/usr/lib/modules/$KVER/updates/$ko.ko
    [ -f "$file" ] || { echo "$file missing"; exit 1; }
    vermagic=$(modinfo -F vermagic "$file")
    [[ "$vermagic" == "$KVER "* ]] || { echo "$ko vermagic '$vermagic' is not for $KVER"; exit 1; }
    resolved=$(realpath "$(modinfo -k "$KVER" -F filename "$ko")")
    [ "$resolved" = "$file" ] || { echo "modprobe $ko resolves to $resolved, not $file"; exit 1; }
    echo "$ko: $file, vermagic $KVER"
done
# NTFSPLUS opt-in (55-ntfsplus.sh): the type ntfs blacklisted, no generic
# mount.ntfs helper left to hijack it.
[ "$(grep -vE '^\s*(#|$)' /usr/lib/modprobe.d/bazzite-mx-ntfsplus.conf)" = "blacklist ntfs" ] || { echo "bazzite-mx-ntfsplus.conf is not 'blacklist ntfs'"; exit 1; }
for h in /usr/bin/mount.ntfs /usr/sbin/mount.ntfs; do
    [ ! -e "$h" ] && [ ! -L "$h" ] || { echo "$h still present"; exit 1; }
done
echo "ntfs: blacklisted, mount.ntfs helpers gone"
echo "== image-info.json"
info_version=$(jq -r '.version // empty' /usr/share/ublue-os/image-info.json)
[ "$info_version" = "$VERSION" ] || { echo "image-info.json version '$info_version', label '$VERSION'"; exit 1; }
echo "version $VERSION"
EOF

check_image() {
    local image=$1 file=$2 json kver version
    json=$(podman image inspect --format '{{json .Labels}}' "$image")
    check_labels "$json" "$file" || exit 1
    kver=$(sed -n 's/^ostree\.linux=//p' "$file")
    version=$(sed -n 's/^org\.opencontainers\.image\.version=//p' "$file")
    [ -n "$kver" ] && [ -n "$version" ] || fail "$file has no ostree.linux or version label"
    # Read on the mounted image: podman populates /run inside a container,
    # where bootc's own lint cannot see the difference.
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
    podman run --rm --tmpfs /run --tmpfs /tmp --network=none \
        --env "KVER=$kver" --env "VERSION=$version" --env "PROBE_PACKAGES=$PROBE_PACKAGES" \
        "$image" bash -c "$PROBE" || fail "runtime probe failed on $image"
    echo "check-image ok: $image"
}

self_test() {
    local dir good json
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    good=$dir/labels.txt
    printf '%s\n' \
        "org.opencontainers.image.title=bazzite-mx" \
        "org.opencontainers.image.version=44.20260902.dev" \
        "ostree.linux=7.2.1-ogc4.1.fc44.x86_64" \
        "containers.bootc=1" > "$good"
    json='{"org.opencontainers.image.title":"bazzite-mx","org.opencontainers.image.version":"44.20260902.dev","ostree.linux":"7.2.1-ogc4.1.fc44.x86_64","containers.bootc":"1","io.buildah.version":"1.43.2"}'
    check_labels "$json" "$good" > /dev/null || fail "self-test: matching labels refused"
    if check_labels "$(jq -c 'del(."ostree.linux")' <<< "$json")" "$good" > /dev/null 2>&1; then
        fail "self-test: missing label accepted"
    fi
    if check_labels "$(jq -c '."org.opencontainers.image.version" = "44.20260902"' <<< "$json")" "$good" > /dev/null 2>&1; then
        fail "self-test: changed label accepted"
    fi
    if check_labels "$(jq -c '."org.opencontainers.image.title" = "Bazzite"' <<< "$json")" "$good" > /dev/null 2>&1; then
        fail "self-test: the base's title accepted"
    fi
    : > "$dir/empty.txt"
    if check_labels "$json" "$dir/empty.txt" > /dev/null 2>&1; then
        fail "self-test: empty labels file accepted"
    fi
    echo "self-test ok: 1 matching label set accepted, 4 bad inputs refused"
}

case "${1:-}" in
    --self-test) self_test ;;
    "" | -*) fail "usage: check-image.sh <image> <labels-file> | --self-test" ;;
    *)
        [ $# -eq 2 ] || fail "usage: check-image.sh <image> <labels-file>"
        [ -f "$2" ] || fail "labels file '$2' missing"
        check_image "$1" "$2"
        ;;
esac
