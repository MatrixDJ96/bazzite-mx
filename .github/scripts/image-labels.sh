#!/usr/bin/env bash
# The one owner of the labels an image carries, as KEY=value lines. Both the
# build and the compose step read them: a chunked image inherits no config, so
# every label has to be restated there or the image keeps the base's.
#
#   image-labels.sh <coords-file> <release-tag> <revision>
#       coords-file: the KEY=value output of resolve-base.sh
#       release-tag: the tag a release stamps, or "" for a sandbox build
#                    (then the version is <base version>.dev)
#       revision:    the commit the image is built from
#   image-labels.sh --self-test
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

REPO_URL=https://github.com/MatrixDJ96/bazzite-mx
VENDOR=matrixdj96
DESCRIPTION="Personal bootc image on Bazzite (KDE, stable): the system layer of a three-host fleet"

labels() {
    local coords=$1 tag=$2 revision=$3 created=$4
    local image_name base_name base_digest base_version kernel_version fedora_version version
    [ -f "$coords" ] || {
        err "coords file '$coords' missing"
        return 1
    }
    image_name=$(sed -n 's/^image_name=//p' "$coords")
    base_name=$(sed -n 's/^base_name=//p' "$coords")
    base_digest=$(sed -n 's/^base_digest=//p' "$coords")
    base_version=$(sed -n 's/^base_version=//p' "$coords")
    kernel_version=$(sed -n 's/^kernel_version=//p' "$coords")
    fedora_version=$(sed -n 's/^fedora_version=//p' "$coords")
    [[ "$image_name" =~ ^bazzite-mx(-nvidia(-open)?)?$ ]] || {
        err "no image_name in $coords: '$image_name'"
        return 1
    }
    [[ "$base_name" =~ ^ghcr\.io/ublue-os/[a-z-]+$ ]] || {
        err "no base_name in $coords: '$base_name'"
        return 1
    }
    [[ "$base_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
        err "no base_digest in $coords: '$base_digest'"
        return 1
    }
    [[ "$base_version" =~ ^[0-9]+\.[0-9]{8} ]] || {
        err "no base_version in $coords: '$base_version'"
        return 1
    }
    [[ "$kernel_version" =~ ^[0-9]+\.[0-9]+.*\.fc[0-9]+\.x86_64$ ]] || {
        err "no kernel_version in $coords: '$kernel_version'"
        return 1
    }
    [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
        err "revision must be a full commit sha: '$revision'"
        return 1
    }
    [[ "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
        err "created must be an RFC 3339 UTC timestamp: '$created'"
        return 1
    }
    if [ -n "$tag" ]; then
        [[ "$tag" =~ $TAG_SHAPE ]] || {
            err "release tag must be <fedora>.<yyyymmdd>[.N]: '$tag'"
            return 1
        }
        # release.yml derives the tag from one flavour's base and stamps it
        # on all three, so every flavour's kernel must be that Fedora's.
        [ "${tag%%.*}" = "$fedora_version" ] || {
            err "release tag $tag names Fedora ${tag%%.*}, the base's kernel is fc${fedora_version:-?} ($kernel_version)"
            return 1
        }
        version=$tag
    else
        version=${base_version}.dev
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

self_test() {
    local dir good rev created out n=0
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    good=$dir/good.env
    printf '%s\n' \
        image_name=bazzite-mx \
        base_name=ghcr.io/ublue-os/bazzite \
        base_image=ghcr.io/ublue-os/bazzite@sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76 \
        base_digest=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76 \
        base_version=44.20260902 \
        kernel_version=7.2.1-ogc4.1.fc44.x86_64 \
        fedora_version=44 > "$good"
    rev=8cfea1732f154089321597d3c52084db3e9dd8ce
    created=2026-09-02T14:00:00Z
    out=$(labels "$good" "" "$rev" "$created") || fail "self-test: known-good coords refused"
    [ "$(wc -l <<< "$out")" -eq 14 ] || fail "self-test: expected 14 labels, got $(wc -l <<< "$out")"
    grep -qx 'org.opencontainers.image.version=44.20260902.dev' <<< "$out" || fail "self-test: sandbox version is not <base>.dev"
    grep -qx 'ostree.linux=7.2.1-ogc4.1.fc44.x86_64' <<< "$out" || fail "self-test: ostree.linux not taken from the coords"
    grep -qx 'org.opencontainers.image.base.name=ghcr.io/ublue-os/bazzite:stable' <<< "$out" || fail "self-test: base.name not derived"
    labels "$good" 44.20260903.1 "$rev" "$created" | grep -qx 'org.opencontainers.image.version=44.20260903.1' \
        || fail "self-test: release tag not stamped as the version"
    sed 's/^image_name=.*/image_name=bazzite-mx-nvidia/' "$good" > "$dir/closed.env"
    labels "$dir/closed.env" "" "$rev" "$created" | grep -qx 'org.opencontainers.image.title=bazzite-mx-nvidia' \
        || fail "self-test: the closed flavour's coords refused"
    grep -v '^kernel_version=' "$good" > "$dir/nokernel.env"
    for bad in \
        "$dir/nokernel.env|$rev|$created" \
        "$good|8cfea17|$created" \
        "$good|$rev|2026-09-02" \
        "$dir/absent.env|$rev|$created"; do
        n=$((n + 1))
        IFS='|' read -r coords revision stamp <<< "$bad"
        if labels "$coords" "" "$revision" "$stamp" > /dev/null 2>&1; then
            fail "self-test: known-bad input $n produced labels"
        fi
    done
    if labels "$good" v44.20260903 "$rev" "$created" > /dev/null 2>&1; then
        fail "self-test: release tag 'v44.20260903' accepted"
    fi
    sed 's/^image_name=.*/image_name=bazzite-mx-nvidia-closed/' "$good" > "$dir/suffix.env"
    n=$((n + 1))
    if labels "$dir/suffix.env" "" "$rev" "$created" > /dev/null 2>&1; then
        fail "self-test: image_name 'bazzite-mx-nvidia-closed' accepted"
    fi
    n=$((n + 1))
    if labels "$good" 45.20260903 "$rev" "$created" > /dev/null 2>&1; then
        fail "self-test: release tag 45.20260903 accepted on a Fedora 44 kernel"
    fi
    echo "self-test ok: 2 coords files labelled, $((n + 1)) bad inputs refused"
}

case "${1:-}" in
    --self-test) self_test ;;
    "" | -*) fail "usage: image-labels.sh <coords-file> <release-tag> <revision> | --self-test" ;;
    *)
        [ $# -eq 3 ] || fail "usage: image-labels.sh <coords-file> <release-tag> <revision>"
        labels "$1" "$2" "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || exit 1
        ;;
esac
