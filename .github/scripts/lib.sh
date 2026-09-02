#!/usr/bin/env bash
# The coordinates of this repository and the helpers every CI script shares,
# sourced after the script's own `set`.
#
#   lib.sh --self-test    prove read_env, image_of, TAG_SHAPE and absent_error
#                         classify known-bad input
# shellcheck disable=SC2034  # read by the sourcing scripts
REPO=${REPO:-MatrixDJ96/bazzite-mx}
REGISTRY=ghcr.io/matrixdj96
BASE_REGISTRY=ghcr.io/ublue-os
PACKAGES="bazzite-mx bazzite-mx-nvidia-open bazzite-mx-nvidia"
FLAVOURS="bazzite bazzite-nvidia-open bazzite-nvidia"
TAG_SHAPE='^[0-9]+\.[0-9]{8}(\.[0-9]+)?$'

SCRIPT_NAME=${0##*/}
SCRIPT_NAME=${SCRIPT_NAME%.sh}

fail() {
    echo "$SCRIPT_NAME: $*" >&2
    exit 1
}

# err returns 1 instead of exiting, so the self-test can call a function
# under `if` without killing the script and losing the message.
err() {
    echo "$SCRIPT_NAME: $*" >&2
    return 1
}

# emit also appends to GITHUB_OUTPUT when a workflow set it.
emit() {
    printf '%s\n' "$@"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s\n' "$@" >> "$GITHUB_OUTPUT"
    fi
}

# image_of <flavour>: the image built on that base; the one map from a
# flavour to its image, an unknown flavour refused.
image_of() {
    case "$1" in
        bazzite) echo bazzite-mx ;;
        bazzite-nvidia-open) echo bazzite-mx-nvidia-open ;;
        bazzite-nvidia) echo bazzite-mx-nvidia ;;
        *)
            err "unknown flavour '$1' (${FLAVOURS// / | })"
            return 1
            ;;
    esac
}

# read_env sets image_name, digest, base_name and base_digest in the caller;
# the image must be the one built on that base.
read_env() {
    local file=$1
    [ -f "$file" ] || {
        err "env file '$file' missing"
        return 1
    }
    image_name=$(sed -n 's/^image_name=//p' "$file")
    digest=$(sed -n 's/^digest=//p' "$file")
    base_name=$(sed -n 's/^base_name=//p' "$file")
    base_digest=$(sed -n 's/^base_digest=//p' "$file")
    [[ "$image_name" =~ ^bazzite-mx(-nvidia(-open)?)?$ ]] || {
        err "$file: no image_name: '$image_name'"
        return 1
    }
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
        err "$file: no image digest: '$digest'"
        return 1
    }
    [[ "$base_name" =~ ^ghcr\.io/ublue-os/[a-z-]+$ ]] || {
        err "$file: no base_name: '$base_name'"
        return 1
    }
    [[ "$base_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
        err "$file: no base_digest: '$base_digest'"
        return 1
    }
    [ "$(image_of "${base_name#"${BASE_REGISTRY}/"}" 2> /dev/null)" = "$image_name" ] || {
        err "$file: $image_name is not the image built on $base_name"
        return 1
    }
}

# The only two skopeo errors that mean the image is not there: a tag that
# does not exist and a package never published. Anything else is a failure.
absent_error() {
    grep -qE 'manifest unknown|name unknown' <<< "$1"
}

lib_self_test() {
    local dir n=0 good bad tag
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    good=$dir/good.env
    printf '%s\n' image_name=bazzite-mx-nvidia-open \
        digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        base_name=ghcr.io/ublue-os/bazzite-nvidia-open \
        base_digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$good"
    read_env "$good" || fail "self-test: known-good env file refused"
    [ "$image_name" = bazzite-mx-nvidia-open ] && [ "$base_name" = ghcr.io/ublue-os/bazzite-nvidia-open ] \
        || fail "self-test: values not read: '$image_name' '$base_name'"
    sed -e 's/^image_name=.*/image_name=bazzite-mx-nvidia/' -e 's#^base_name=.*#base_name=ghcr.io/ublue-os/bazzite-nvidia#' "$good" > "$dir/closed.env"
    read_env "$dir/closed.env" || fail "self-test: the closed flavour's env file refused"
    sed 's/^digest=.*/digest=sha256:short/' "$good" > "$dir/bad1.env"
    sed 's/^image_name=.*/image_name=bazzite/' "$good" > "$dir/bad2.env"
    sed 's|^base_name=.*|base_name=docker.io/library/fedora|' "$good" > "$dir/bad3.env"
    sed '/^base_digest=/d' "$good" > "$dir/bad4.env"
    sed 's/^image_name=.*/image_name=bazzite-mx-nvidia-closed/' "$good" > "$dir/bad5.env"
    sed 's/^image_name=.*/image_name=bazzite-mx/' "$good" > "$dir/bad6.env"
    for bad in "$dir"/bad[1-6].env "$dir/absent.env"; do
        n=$((n + 1))
        if read_env "$bad" > /dev/null 2>&1; then
            fail "self-test: known-bad env file $n accepted"
        fi
    done
    [ "$(image_of bazzite-nvidia-open)" = bazzite-mx-nvidia-open ] || fail "self-test: image of a flavour not derived"
    n=$((n + 1))
    if image_of bazzite-deck > /dev/null 2>&1; then
        fail "self-test: an unknown flavour given an image"
    fi
    for tag in 44.20260903 44.20260903.2; do
        [[ "$tag" =~ $TAG_SHAPE ]] || fail "self-test: release tag $tag refused"
    done
    for tag in 44.2026090 testing-44.20260903 44.20260903-rc 20260903; do
        n=$((n + 1))
        if [[ "$tag" =~ $TAG_SHAPE ]]; then
            fail "self-test: '$tag' taken for a release tag"
        fi
    done
    absent_error 'reading manifest stable in ghcr.io/x/y: manifest unknown' || fail "self-test: manifest unknown not absent"
    absent_error 'Error listing repository tags: fetching tags list: name unknown' || fail "self-test: name unknown not absent"
    n=$((n + 1))
    if absent_error 'unauthorized: authentication required' > /dev/null 2>&1; then
        fail "self-test: an authentication error taken for an absent image"
    fi
    echo "self-test ok: 2 env files read, 1 image derived, 2 release tags matched, 2 absence errors classified, $n bad inputs refused"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    case "${1:-}" in
        --self-test) lib_self_test ;;
        *)
            echo "usage: lib.sh --self-test (otherwise sourced by the CI scripts)" >&2
            exit 1
            ;;
    esac
fi
