#!/usr/bin/env bash
# The output of a build script: a section fold for the GitHub Actions log, a
# progress line, and the one way to fail the build. Sourced by lib/env.sh;
# the kmod-builder stage and tests 21, 22, 50 and 55 source it on their own.
#
# Output contract: `::group::` and `::endgroup::` fold a section in the
# Actions log; `FAIL: <reason>` on stderr is what the test runner greps for.

group() {
    echo "::group:: === $* ==="
}

endgroup() {
    echo "::endgroup::"
}

log() {
    echo "=== $* ==="
}

fail_build() {
    echo "FAIL: $*" >&2
    exit 1
}
