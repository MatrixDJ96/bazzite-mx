#!/usr/bin/env bash
# The coordinates of this repository and the helpers the CI scripts share: the
# error functions, `emit`, the flavour-to-image map, the env-file reader, the
# release-tag shape, the absent-image classifier and the self-test helpers.
#
# Sourced by every script under .github/scripts/ but check-form.sh and
# check-commits.sh, after the script's own `set`; run only for its self-test.
#
# Usage: lib.sh --self-test
#          prove image_of, TAG_SHAPE, absent_error and require_option_value
#          classify known-bad input
# Exit status (self-test): 0 with a `self-test ok: …` line; 1 on the first
#   known-bad input accepted or known-good input refused.

# shellcheck disable=SC2034  # read by the sourcing scripts
REPO=${REPO:-MatrixDJ96/bazzite-mx}
REGISTRY=ghcr.io/matrixdj96
BASE_REGISTRY=ghcr.io/ublue-os
PACKAGES="bazzite-mx bazzite-mx-nvidia-open bazzite-mx-nvidia"
FLAVOURS="bazzite bazzite-nvidia-open bazzite-nvidia"

# A release tag, <fedora>.<yyyymmdd>[.N]: .N when the date or a suffix is taken.
TAG_SHAPE='^[0-9]+\.[0-9]{8}(\.[0-9]+)?$'

SCRIPT_NAME=${0##*/}
SCRIPT_NAME=${SCRIPT_NAME%.sh}

# --- errors and outputs -------------------------------------------------------

# exit_with_error <message>: the script's name, the message, exit 1.
exit_with_error() {
    echo "$SCRIPT_NAME: $*" >&2
    exit 1
}

# print_error <message>: the same line, status 1 and no exit, so a self-test can
# call a function under `if` without losing the message.
print_error() {
    echo "$SCRIPT_NAME: $*" >&2
    return 1
}

# require_option_value <option> <value>: exit 1 naming the option when it came
# without its value, so `$2` never reads as unbound in an option loop.
require_option_value() {
    if [ -z "$2" ]; then
        exit_with_error "$1 needs a value"
    fi
}

# fail_self_test <message>: `<script>: self-test: <message>`, exit 1. The
# self-test of every script that sources this file reports a failed check with
# it; most count in REFUSED the known-bad inputs they refused, for the closing
# line.
fail_self_test() {
    exit_with_error "self-test: $*"
}

REFUSED=0

# emit <line>...: on stdout, and in GITHUB_OUTPUT when a workflow set it.
emit() {
    printf '%s\n' "$@"

    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s\n' "$@" >> "$GITHUB_OUTPUT"
    fi
}

# --- flavours and images ------------------------------------------------------

# image_of <flavour>: the image built on that base; the one map from a flavour
# to its image, an unknown flavour refused.
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
# caller from a `key=value` file.
read_env() {
    local file=$1

    image_name=$(sed -n 's/^image_name=//p' "$file")
    digest=$(sed -n 's/^digest=//p' "$file")
    base_name=$(sed -n 's/^base_name=//p' "$file")
    base_digest=$(sed -n 's/^base_digest=//p' "$file")
}

# --- registry errors ----------------------------------------------------------

# absent_error <skopeo stderr>: status 0 for the only two errors that mean the
# image is not there, a tag that does not exist and a package never published.
# Anything else is a failure.
absent_error() {
    local message=$1

    grep -qE 'manifest unknown|name unknown' <<< "$message"
}

# --- self-test ----------------------------------------------------------------

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

# self_test_option_value: an option with its value passes, one without it is
# refused with a line naming the option.
self_test_option_value() {
    local output

    if ! require_option_value --release-tag 44.20260909; then
        fail_self_test "an option with its value refused"
    fi

    REFUSED=$((REFUSED + 1))

    if output=$(require_option_value --release-tag "" 2>&1); then
        fail_self_test "an option without its value accepted"
    fi

    if ! grep -q -- '--release-tag needs a value' <<< "$output"; then
        fail_self_test "the refused option not named: ${output:-no output}"
    fi
}

lib_self_test() {
    self_test_image_of
    self_test_tag_shape
    self_test_absent_error
    self_test_option_value

    echo "self-test ok: 1 image derived, 2 release tags matched," \
        "2 absence errors classified, 1 option value required, $REFUSED bad inputs refused"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    case "${1:-}" in
        --self-test)
            lib_self_test
            ;;
        *)
            echo "lib: usage: lib.sh --self-test (otherwise sourced by the CI scripts)" >&2
            exit 1
            ;;
    esac
fi
