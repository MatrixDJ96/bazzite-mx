#!/usr/bin/env bash
# The coordinates of this repository and the helpers every CI script shares:
# the error functions, `emit`, the flavour-to-image map, the env-file reader,
# the release-tag shape, the absent-image classifier and the self-test
# helpers. Sourced by every script under .github/scripts/ after the script's
# own `set`; run only for its self-test.
#
# Usage: lib.sh --self-test    prove read_env, image_of, TAG_SHAPE and
#                              absent_error classify known-bad input
# Exit status (self-test): 0 with a `self-test ok: …` line; 1 on the first
#   known-bad input accepted or known-good input refused.

# shellcheck disable=SC2034  # read by the sourcing scripts
REPO=${REPO:-MatrixDJ96/bazzite-mx}
REGISTRY=ghcr.io/matrixdj96
BASE_REGISTRY=ghcr.io/ublue-os
PACKAGES="bazzite-mx bazzite-mx-nvidia-open bazzite-mx-nvidia"
FLAVOURS="bazzite bazzite-nvidia-open bazzite-nvidia"

# A release tag: <fedora>.<yyyymmdd>, with .N when the date is taken.
TAG_SHAPE='^[0-9]+\.[0-9]{8}(\.[0-9]+)?$'

SCRIPT_NAME=${0##*/}
SCRIPT_NAME=${SCRIPT_NAME%.sh}

# --- errors and outputs -------------------------------------------------------

# exit_with_error <message>: the script's name, the message, exit 1. Only a
# command calls it: a function a caller runs under `if` uses print_error and
# returns its status.
exit_with_error() {
    echo "$SCRIPT_NAME: $*" >&2
    exit 1
}

# print_error <message>: the same line, status 1 and no exit, so a self-test
# can call a function under `if` without losing the message.
print_error() {
    echo "$SCRIPT_NAME: $*" >&2
    return 1
}

# fail_self_test <message>: `<script>: self-test: <message>`, exit 1. The
# self-test of every CI script reports a check that failed with it, and counts
# in REFUSED the known-bad inputs it refused, for its closing line.
fail_self_test() {
    exit_with_error "self-test: $*"
}

REFUSED=0

# emit <line>...: on stdout, and appended to GITHUB_OUTPUT when a workflow
# set it.
emit() {
    printf '%s\n' "$@"

    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s\n' "$@" >> "$GITHUB_OUTPUT"
    fi
}

# --- flavours and images ------------------------------------------------------

# image_of <flavour>: the image built on that base; the one map from a
# flavour to its image, an unknown flavour refused.
image_of() {
    local flavour=$1

    case "$flavour" in
        bazzite)
            echo bazzite-mx
            ;;
        bazzite-nvidia-open)
            echo bazzite-mx-nvidia-open
            ;;
        bazzite-nvidia)
            echo bazzite-mx-nvidia
            ;;
        *)
            print_error "unknown flavour '$flavour' (${FLAVOURS// / | })"
            return 1
            ;;
    esac
}

# --- the env file -------------------------------------------------------------

# read_env <file>: sets image_name, digest, base_name and base_digest in the
# caller from a `key=value` file; status 1 when a value is missing or has the
# wrong shape, or the image is not the one built on that base.
read_env() {
    local file=$1
    local flavour

    if [ ! -f "$file" ]; then
        print_error "env file '$file' missing"
        return 1
    fi

    image_name=$(sed -n 's/^image_name=//p' "$file")
    digest=$(sed -n 's/^digest=//p' "$file")
    base_name=$(sed -n 's/^base_name=//p' "$file")
    base_digest=$(sed -n 's/^base_digest=//p' "$file")

    if [[ ! "$image_name" =~ ^bazzite-mx(-nvidia(-open)?)?$ ]]; then
        print_error "$file: no image_name: '$image_name'"
        return 1
    fi

    if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        print_error "$file: no image digest: '$digest'"
        return 1
    fi

    if [[ ! "$base_name" =~ ^ghcr\.io/ublue-os/[a-z-]+$ ]]; then
        print_error "$file: no base_name: '$base_name'"
        return 1
    fi

    if [[ ! "$base_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        print_error "$file: no base_digest: '$base_digest'"
        return 1
    fi

    flavour=${base_name#"${BASE_REGISTRY}/"}
    if [ "$(image_of "$flavour" 2> /dev/null)" != "$image_name" ]; then
        print_error "$file: $image_name is not the image built on $base_name"
        return 1
    fi
}

# --- registry errors ----------------------------------------------------------

# absent_error <skopeo stderr>: status 0 for the only two errors that mean
# the image is not there, a tag that does not exist and a package never
# published. Anything else is a failure.
absent_error() {
    local message=$1

    grep -qE 'manifest unknown|name unknown' <<< "$message"
}

# --- self-test ----------------------------------------------------------------

# self_test_write_good_env <file>: a complete env file of the open NVIDIA
# flavour.
self_test_write_good_env() {
    local file=$1
    local digest_a=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    local digest_b=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

    printf '%s\n' image_name=bazzite-mx-nvidia-open \
        "digest=$digest_a" \
        base_name=ghcr.io/ublue-os/bazzite-nvidia-open \
        "base_digest=$digest_b" > "$file"
}

# self_test_read_env <dir>: the two good files read, seven bad ones refused.
self_test_read_env() {
    local dir=$1
    local good=$dir/good.env
    local bad

    self_test_write_good_env "$good"
    if ! read_env "$good"; then
        fail_self_test "known-good env file refused"
    fi
    if [ "$image_name" != bazzite-mx-nvidia-open ] \
        || [ "$base_name" != ghcr.io/ublue-os/bazzite-nvidia-open ]; then
        fail_self_test "values not read: '$image_name' '$base_name'"
    fi

    sed -e 's/^image_name=.*/image_name=bazzite-mx-nvidia/' \
        -e 's#^base_name=.*#base_name=ghcr.io/ublue-os/bazzite-nvidia#' "$good" > "$dir/closed.env"
    if ! read_env "$dir/closed.env"; then
        fail_self_test "the closed flavour's env file refused"
    fi

    sed 's/^digest=.*/digest=sha256:short/' "$good" > "$dir/bad1.env"
    sed 's/^image_name=.*/image_name=bazzite/' "$good" > "$dir/bad2.env"
    sed 's|^base_name=.*|base_name=docker.io/library/fedora|' "$good" > "$dir/bad3.env"
    sed '/^base_digest=/d' "$good" > "$dir/bad4.env"
    sed 's/^image_name=.*/image_name=bazzite-mx-nvidia-closed/' "$good" > "$dir/bad5.env"
    sed 's/^image_name=.*/image_name=bazzite-mx/' "$good" > "$dir/bad6.env"
    for bad in "$dir"/bad[1-6].env "$dir/absent.env"; do
        REFUSED=$((REFUSED + 1))
        if read_env "$bad" > /dev/null 2>&1; then
            fail_self_test "known-bad env file $REFUSED accepted"
        fi
    done
}

# self_test_image_of: one image derived, one unknown flavour refused.
self_test_image_of() {
    if [ "$(image_of bazzite-nvidia-open)" != bazzite-mx-nvidia-open ]; then
        fail_self_test "image of a flavour not derived"
    fi

    REFUSED=$((REFUSED + 1))
    if image_of bazzite-deck > /dev/null 2>&1; then
        fail_self_test "an unknown flavour given an image"
    fi
}

# self_test_tag_shape: two release tags matched, four other strings refused.
self_test_tag_shape() {
    local tag

    for tag in 44.20260903 44.20260903.2; do
        if [[ ! "$tag" =~ $TAG_SHAPE ]]; then
            fail_self_test "release tag $tag refused"
        fi
    done

    for tag in 44.2026090 testing-44.20260903 44.20260903-rc 20260903; do
        REFUSED=$((REFUSED + 1))
        if [[ "$tag" =~ $TAG_SHAPE ]]; then
            fail_self_test "'$tag' taken for a release tag"
        fi
    done
}

# self_test_absent_error: the two absence errors classified, an authentication
# error not.
self_test_absent_error() {
    if ! absent_error 'reading manifest stable in ghcr.io/x/y: manifest unknown'; then
        fail_self_test "manifest unknown not absent"
    fi

    if ! absent_error 'Error listing repository tags: fetching tags list: name unknown'; then
        fail_self_test "name unknown not absent"
    fi

    REFUSED=$((REFUSED + 1))
    if absent_error 'unauthorized: authentication required' > /dev/null 2>&1; then
        fail_self_test "an authentication error taken for an absent image"
    fi
}

lib_self_test() {
    local dir

    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN

    self_test_read_env "$dir"
    self_test_image_of
    self_test_tag_shape
    self_test_absent_error

    echo "self-test ok: 2 env files read, 1 image derived, 2 release tags matched," \
        "2 absence errors classified, $REFUSED bad inputs refused"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    case "${1:-}" in
        --self-test)
            lib_self_test
            ;;
        *)
            echo "usage: lib.sh --self-test (otherwise sourced by the CI scripts)" >&2
            exit 1
            ;;
    esac
fi
