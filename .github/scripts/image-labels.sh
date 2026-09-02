#!/usr/bin/env bash
# The one owner of the labels an image carries, as KEY=value lines. Both the
# build and the compose step read them: a chunked image inherits no config,
# so every label has to be restated there or the image keeps the base's.
#
# Usage: image-labels.sh <coords-file> <release-tag> <revision>
#          <coords-file>  the KEY=value output of resolve-base.sh
#          <release-tag>  the tag a release stamps, or "" for a sandbox build,
#                         whose version is then <base version>.dev
#          <revision>     the full sha of the commit the image is built from
#        image-labels.sh --self-test
# Output: the 14 labels, one KEY=value line each, on stdout.
# Exit status: 0 labels written; 1 when a coordinate, the revision or the
#   tag is missing or malformed, or the tag names a Fedora other than the
#   base's kernel's, the reason on stderr as `image-labels: …`.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

REPO_URL=https://github.com/MatrixDJ96/bazzite-mx
VENDOR=matrixdj96
DESCRIPTION="Personal bootc image on Bazzite (KDE, stable): the system layer of a three-host fleet"

# --- the coordinates ----------------------------------------------------------

# read_coords <file>: sets image_name, base_name, base_digest, base_version,
# kernel_version and fedora_version in the caller from a coords file; status
# 1 when the file is missing or a value has the wrong shape.
read_coords() {
    local file=$1

    if [ ! -f "$file" ]; then
        print_error "coords file '$file' missing"
        return 1
    fi

    image_name=$(sed -n 's/^image_name=//p' "$file")
    base_name=$(sed -n 's/^base_name=//p' "$file")
    base_digest=$(sed -n 's/^base_digest=//p' "$file")
    base_version=$(sed -n 's/^base_version=//p' "$file")
    kernel_version=$(sed -n 's/^kernel_version=//p' "$file")
    fedora_version=$(sed -n 's/^fedora_version=//p' "$file")

    if [[ ! "$image_name" =~ ^bazzite-mx(-nvidia(-open)?)?$ ]]; then
        print_error "no image_name in $file: '$image_name'"
        return 1
    fi
    if [[ ! "$base_name" =~ ^ghcr\.io/ublue-os/[a-z-]+$ ]]; then
        print_error "no base_name in $file: '$base_name'"
        return 1
    fi
    if [[ ! "$base_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        print_error "no base_digest in $file: '$base_digest'"
        return 1
    fi
    if [[ ! "$base_version" =~ ^[0-9]+\.[0-9]{8} ]]; then
        print_error "no base_version in $file: '$base_version'"
        return 1
    fi
    if [[ ! "$kernel_version" =~ ^[0-9]+\.[0-9]+.*\.fc[0-9]+\.x86_64$ ]]; then
        print_error "no kernel_version in $file: '$kernel_version'"
        return 1
    fi
}

# --- the labels ---------------------------------------------------------------

# image_version <release tag> <base version> <fedora version> <kernel version>:
# the version label, the tag for a release and <base version>.dev for a
# sandbox build. A tag naming another Fedora than the base's kernel is
# refused: release.yml derives the tag from one flavour's base and stamps it
# on all three, so every flavour's kernel must be that Fedora's.
image_version() {
    local tag=$1
    local base_version=$2
    local fedora_version=$3
    local kernel_version=$4

    if [ -z "$tag" ]; then
        echo "${base_version}.dev"
        return 0
    fi

    if [[ ! "$tag" =~ $TAG_SHAPE ]]; then
        print_error "release tag must be <fedora>.<yyyymmdd>[.N]: '$tag'"
        return 1
    fi
    if [ "${tag%%.*}" != "$fedora_version" ]; then
        print_error "release tag $tag names Fedora ${tag%%.*}," \
            "the base's kernel is fc${fedora_version:-?} ($kernel_version)"
        return 1
    fi

    echo "$tag"
}

# labels <coords file> <release tag> <revision> <created>: the 14 labels on
# stdout; status 1 with the reason when any input is refused.
labels() {
    local coords=$1
    local tag=$2
    local revision=$3
    local created=$4
    local image_name base_name base_digest base_version kernel_version fedora_version version

    if ! read_coords "$coords"; then
        return 1
    fi
    if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
        print_error "revision must be a full commit sha: '$revision'"
        return 1
    fi
    if [[ ! "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        print_error "created must be an RFC 3339 UTC timestamp: '$created'"
        return 1
    fi
    if ! version=$(image_version "$tag" "$base_version" "$fedora_version" "$kernel_version"); then
        return 1
    fi

    printf '%s\n' \
        "org.opencontainers.image.title=${image_name}" \
        "org.opencontainers.image.description=${DESCRIPTION}" \
        "org.opencontainers.image.source=${REPO_URL}" \
        "org.opencontainers.image.url=${REPO_URL}" \
        "org.opencontainers.image.vendor=${VENDOR}" \
        "org.opencontainers.image.licenses=Apache-2.0" \
        "org.opencontainers.image.version=${version}" \
        "org.opencontainers.image.revision=${revision}" \
        "org.opencontainers.image.created=${created}" \
        "org.opencontainers.image.base.name=${base_name}:stable" \
        "org.opencontainers.image.base.digest=${base_digest}" \
        "ostree.bootable=true" \
        "ostree.linux=${kernel_version}" \
        "containers.bootc=1"
}

# --- self-test ----------------------------------------------------------------

SELF_TEST_REVISION=8cfea1732f154089321597d3c52084db3e9dd8ce
SELF_TEST_CREATED=2026-09-02T14:00:00Z
SELF_TEST_BASE_DIGEST=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76

# self_test_write_coords <file>: the coords of a bazzite-mx build on a
# Fedora 44 base.
self_test_write_coords() {
    local file=$1

    printf '%s\n' \
        image_name=bazzite-mx \
        base_name=ghcr.io/ublue-os/bazzite \
        "base_image=ghcr.io/ublue-os/bazzite@$SELF_TEST_BASE_DIGEST" \
        "base_digest=$SELF_TEST_BASE_DIGEST" \
        base_version=44.20260902 \
        kernel_version=7.2.1-ogc4.1.fc44.x86_64 \
        fedora_version=44 > "$file"
}

# self_test_good_coords <dir> <good>: 14 labels for a sandbox build with the
# .dev version, the kernel and the base name derived; a release tag stamped
# as the version; the closed flavour's coords accepted.
self_test_good_coords() {
    local dir=$1
    local good=$2
    local output

    if ! output=$(labels "$good" "" "$SELF_TEST_REVISION" "$SELF_TEST_CREATED"); then
        fail_self_test "known-good coords refused"
    fi
    if [ "$(wc -l <<< "$output")" -ne 14 ]; then
        fail_self_test "expected 14 labels, got $(wc -l <<< "$output")"
    fi
    if ! grep -qx 'org.opencontainers.image.version=44.20260902.dev' <<< "$output"; then
        fail_self_test "sandbox version is not <base>.dev"
    fi
    if ! grep -qx 'ostree.linux=7.2.1-ogc4.1.fc44.x86_64' <<< "$output"; then
        fail_self_test "ostree.linux not taken from the coords"
    fi
    if ! grep -qx 'org.opencontainers.image.base.name=ghcr.io/ublue-os/bazzite:stable' \
        <<< "$output"; then
        fail_self_test "base.name not derived"
    fi

    output=$(labels "$good" 44.20260903.1 "$SELF_TEST_REVISION" "$SELF_TEST_CREATED")
    if ! grep -qx 'org.opencontainers.image.version=44.20260903.1' <<< "$output"; then
        fail_self_test "release tag not stamped as the version"
    fi

    sed 's/^image_name=.*/image_name=bazzite-mx-nvidia/' "$good" > "$dir/closed.env"
    output=$(labels "$dir/closed.env" "" "$SELF_TEST_REVISION" "$SELF_TEST_CREATED")
    if ! grep -qx 'org.opencontainers.image.title=bazzite-mx-nvidia' <<< "$output"; then
        fail_self_test "the closed flavour's coords refused"
    fi
}

# self_test_refused <coords> <tag> <revision> <created> <what>: one known-bad
# input refused by labels.
self_test_refused() {
    local coords=$1
    local tag=$2
    local revision=$3
    local created=$4
    local what=$5

    REFUSED=$((REFUSED + 1))
    if labels "$coords" "$tag" "$revision" "$created" > /dev/null 2>&1; then
        fail_self_test "$what accepted"
    fi
}

# self_test_bad_inputs <dir> <good>: coords without a kernel, a short
# revision, a date instead of a timestamp, an absent coords file, a tag with
# a prefix, an image name with a suffix and a tag of another Fedora refused.
self_test_bad_inputs() {
    local dir=$1
    local good=$2
    local revision=$SELF_TEST_REVISION
    local created=$SELF_TEST_CREATED

    grep -v '^kernel_version=' "$good" > "$dir/nokernel.env"
    self_test_refused "$dir/nokernel.env" "" "$revision" "$created" "coords without a kernel"
    self_test_refused "$good" "" 8cfea17 "$created" "a short revision"
    self_test_refused "$good" "" "$revision" 2026-09-02 "a date instead of a timestamp"
    self_test_refused "$dir/absent.env" "" "$revision" "$created" "an absent coords file"
    self_test_refused "$good" v44.20260903 "$revision" "$created" "release tag 'v44.20260903'"

    sed 's/^image_name=.*/image_name=bazzite-mx-nvidia-closed/' "$good" > "$dir/suffix.env"
    self_test_refused "$dir/suffix.env" "" "$revision" "$created" \
        "image_name 'bazzite-mx-nvidia-closed'"
    self_test_refused "$good" 45.20260903 "$revision" "$created" \
        "release tag 45.20260903 on a Fedora 44 kernel"
}

self_test() {
    local dir good

    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    good=$dir/good.env
    self_test_write_coords "$good"

    self_test_good_coords "$dir" "$good"
    self_test_bad_inputs "$dir" "$good"

    echo "self-test ok: 2 coords files labelled, $REFUSED bad inputs refused"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    "" | -*)
        exit_with_error "usage: image-labels.sh <coords-file> <release-tag> <revision>" \
            "| --self-test"
        ;;
    *)
        if [ $# -ne 3 ]; then
            exit_with_error "usage: image-labels.sh <coords-file> <release-tag> <revision>"
        fi
        if ! labels "$1" "$2" "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; then
            exit 1
        fi
        ;;
esac
