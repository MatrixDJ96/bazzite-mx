#!/usr/bin/env bash
# Log helpers. ::group:: folds a section in the GitHub Actions log; die fails
# the build with the reason on stderr.

group() {
    echo "::group:: === $* ==="
}

endgroup() {
    echo "::endgroup::"
}

log() {
    echo "=== $* ==="
}

die() {
    echo "FAIL: $*" >&2
    exit 1
}
