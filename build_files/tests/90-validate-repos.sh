#!/usr/bin/env bash
# Smoke test of 90-validate-repos.sh: the repository gate passes on the
# finished tree and its self-test fails closed.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

VALIDATOR=$(dirname "$(realpath "$0")")/../90-validate-repos.sh

check_gate_passes() {
    if bash "$VALIDATOR" > /dev/null; then
        echo "OK: no enabled third-party repository in the image"
    else
        echo "FAIL: 90-validate-repos.sh rejects the finished tree"
    fi
}

check_self_test() {
    if bash "$VALIDATOR" --self-test > /dev/null; then
        echo "OK: validator self-test refuses the known-bad layouts"
    else
        echo "FAIL: validator self-test"
    fi
}

check_gate_passes
check_self_test
