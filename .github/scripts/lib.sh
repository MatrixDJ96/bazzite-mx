#!/usr/bin/env bash
# The base registry, the flavours and the helpers the CI scripts share:
# the error functions, `emit`, the flavour-to-image map and the self-test
# helpers. Sourced by every script under .github/scripts/ but check-form.sh
# and check-commits.sh, after the script's own `set`; run only for its
# self-test.
#
# Usage: lib.sh --self-test    prove image_of classifies known-bad input
# Exit status (self-test): 0 with a `self-test ok: …` line; 1 on the first
#   known-bad input accepted or known-good input refused.

# shellcheck disable=SC2034  # read by the sourcing scripts
BASE_REGISTRY=ghcr.io/ublue-os
FLAVOURS="bazzite bazzite-nvidia-open bazzite-nvidia"

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
# self-test of every script that sources this file reports a failed check with
# it; most count in REFUSED the known-bad inputs they refused, for the closing
# line.
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

lib_self_test() {
    self_test_image_of

    echo "self-test ok: 1 image derived, $REFUSED bad inputs refused"
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
