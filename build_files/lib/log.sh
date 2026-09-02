#!/usr/bin/env bash
# The output of a build script: a section fold for the GitHub Actions log, a
# progress line, and the one way to fail the build. Sourced by lib/env.sh;
# the kmod-builder stage and tests/55-ntfsplus.sh source it on their own.
#
# Output contract: `::group::` and `::endgroup::` fold a section in the
# Actions log; `FAIL: <reason>` on stderr is what preflight-build.sh and the
# test runner grep for.

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
