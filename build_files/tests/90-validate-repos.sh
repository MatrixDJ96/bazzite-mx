#!/usr/bin/env bash
# Smoke test of 90-validate-repos.sh: its self-test fails closed; the gate
# itself runs in the build.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

VALIDATOR=$(dirname "$(realpath "$0")")/../90-validate-repos.sh

check_self_test validator bash "$VALIDATOR"
