#!/usr/bin/env bash
# Smoke test runner, the second RUN of the Containerfile: offline, on the tree
# clean-stage left. A test prints `OK:` and `FAIL:` lines; any FAIL line, any
# non-zero exit, a test without an OK line and any unpaired script or test
# fails the build.
#
# Usage: run.sh              run every tests/NN-*.sh, each folded in a group
#        run.sh --self-test  the runner on fixture pairs, one good and five bad
# Output: the tests' own lines; `tests: N passed`, the line
#   preflight-build.sh reads, or `tests: FAILED`.
# Exit status: 0 when every test passed; 1 otherwise.
set -euo pipefail

TESTS_DIR=$(dirname "$(realpath "$0")")
BUILD_FILES=$(realpath "$TESTS_DIR/..")
export BUILD_STATE=/usr/lib/bazzite-mx/build-state

# --- the runner ---------------------------------------------------------------

# Pairing guard, both directions: a feature cannot land without its test and
# a test cannot outlive its feature. One FAIL line per unpaired file.
require_pairs() {
    local tests=$1
    local scripts=$2
    local file stem failed=0

    for file in "$scripts"/[0-9][0-9]-*.sh; do
        if [ ! -e "$file" ]; then
            continue
        fi

        stem=$(basename "$file")

        if [ ! -f "$tests/$stem" ]; then
            echo "FAIL: build script $stem has no test tests/$stem"
            failed=1
        fi
    done

    for file in "$tests"/[0-9][0-9]-*.sh; do
        if [ ! -e "$file" ]; then
            continue
        fi

        stem=$(basename "$file")

        if [ ! -f "$scripts/$stem" ]; then
            echo "FAIL: test $stem has no build script $stem"
            failed=1
        fi
    done

    return "$failed"
}

# Runs one test and prints its output; status 1 on a FAIL line, a non-zero
# exit, or no OK line at all, which is what catches a test whose checks
# never ran.
run_one_test() {
    local test=$1
    local name output

    name=$(basename "$test")

    if ! output=$(bash "$test" 2>&1); then
        printf '%s\n' "$output"
        echo "FAIL: test $name exited non-zero"
        return 1
    fi

    printf '%s\n' "$output"

    if grep -q '^FAIL:' <<< "$output"; then
        echo "test $name: FAIL lines above"
        return 1
    fi

    if ! grep -q '^OK:' <<< "$output"; then
        echo "FAIL: test $name printed no OK: line"
        return 1
    fi
}

# run_tests <tests-dir> <build-files-dir>: every test runs, so one run lists
# every failure.
run_tests() {
    local tests=$1
    local scripts=$2
    local test count=0 failed=0

    if ! require_pairs "$tests" "$scripts"; then
        failed=1
    fi

    for test in "$tests"/[0-9][0-9]-*.sh; do
        if [ ! -e "$test" ]; then
            continue
        fi

        count=$((count + 1))
        echo "::group:: === test $(basename "$test") ==="

        if ! run_one_test "$test"; then
            failed=1
        fi

        echo "::endgroup::"
    done

    if [ "$count" -eq 0 ]; then
        echo "FAIL: no tests found under $tests"
        failed=1
    fi

    if [ "$failed" -ne 0 ]; then
        echo "tests: FAILED"
        return 1
    fi

    echo "tests: $count passed"
}

# --- the self-test ------------------------------------------------------------

# Writes <dir>/tests/10-a.sh with <body> as its lines after the shebang.
self_test_write_test() {
    local dir=$1
    local body=$2

    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$dir/tests/10-a.sh"
}

# The fixture under <dir> must be refused; <what> names the layout.
self_test_expect_refused() {
    local dir=$1
    local what=$2

    if run_tests "$dir/tests" "$dir/scripts" > /dev/null; then
        echo "self-test: $what passed"
        exit 1
    fi
}

self_test() {
    local dir

    dir=$(mktemp -d)
    # shellcheck disable=SC2064  # expand now: the local is gone at EXIT
    trap "rm -rf '$dir'" EXIT
    mkdir -p "$dir/tests" "$dir/scripts"

    : > "$dir/scripts/10-a.sh"
    self_test_write_test "$dir" 'echo "OK: a"'

    if ! run_tests "$dir/tests" "$dir/scripts" > /dev/null; then
        echo "self-test: the known-good pair fails"
        exit 1
    fi

    self_test_write_test "$dir" 'echo "OK: a"
echo "FAIL: a broke"'
    self_test_expect_refused "$dir" "a FAIL line"

    self_test_write_test "$dir" 'exit 3'
    self_test_expect_refused "$dir" "a non-zero exit"

    # A test whose checks never ran: exit 0 and not one OK: line.
    self_test_write_test "$dir" 'true'
    self_test_expect_refused "$dir" "a test without an OK: line"

    self_test_write_test "$dir" 'echo "OK: a"'
    : > "$dir/scripts/20-b.sh"
    self_test_expect_refused "$dir" "a build script without a test"
    rm "$dir/scripts/20-b.sh"

    printf '#!/usr/bin/env bash\necho "OK: c"\n' > "$dir/tests/30-c.sh"
    self_test_expect_refused "$dir" "a test without a build script"

    echo "self-test ok: 1 good layout, 5 bad layouts refused"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    "")
        run_tests "$TESTS_DIR" "$BUILD_FILES"
        ;;
    *)
        echo "usage: run.sh [--self-test]" >&2
        exit 1
        ;;
esac
