#!/usr/bin/env bash
# Smoke test runner, the test RUN of the Containerfile: offline, on the tree
# clean-stage left. Two classes of test: tests/NN-<feature>.sh, one per build
# script, and tests/helpers/<name>.sh, for a libexec helper whose cases need
# fixtures. A test prints `OK:` and `FAIL:` lines; any FAIL line, any non-zero
# exit, a test without an OK line and any unpaired script or test fails the
# build.
#
# Usage: run.sh              run every test of both classes, each in its group
#        run.sh --self-test  the runner on fixture pairs, one good and six bad
#   An argument after the first is ignored.
# Output: the tests' own lines; `tests: N passed` or `tests: FAILED`.
# Exit status: 0 when every test passed; 1 otherwise.
set -euo pipefail
shopt -s nullglob

TESTS_DIR=$(dirname "$(realpath "$0")")
BUILD_FILES=$(realpath "$TESTS_DIR/..")
export BUILD_STATE=/usr/lib/bazzite-mx/build-state
# Tests write no .pyc either (docs/gotchas.md § A scriptlet rewrote a packaged `.pyc`).
export PYTHONDONTWRITEBYTECODE=1

# --- the runner ---------------------------------------------------------------

# Pairing guard: a feature cannot land without its test and a test cannot
# outlive its feature. Both directions for the numbered class; one direction
# for the helpers, a test having to name an installed helper while a helper
# may carry its cases in its own `--self-test` instead (bazzite-mx-migrate,
# bazzite-mx-ntfsplus-setup do). One FAIL line per unpaired file.
require_pairs() {
    local tests=$1
    local scripts=$2
    local libexec=$scripts/../system_files/usr/libexec
    local file stem failed=0

    for file in "$scripts"/[0-9][0-9]-*.sh; do
        stem=$(basename "$file")

        if [ ! -f "$tests/$stem" ]; then
            echo "FAIL: build script $stem has no test tests/$stem"
            failed=1
        fi
    done

    for file in "$tests"/[0-9][0-9]-*.sh; do
        stem=$(basename "$file")

        if [ ! -f "$scripts/$stem" ]; then
            echo "FAIL: test $stem has no build script $stem"
            failed=1
        fi
    done

    for file in "$tests"/helpers/*.sh; do
        stem=$(basename "$file" .sh)

        if [ ! -f "$libexec/bazzite-mx-$stem" ]; then
            echo "FAIL: test helpers/$stem.sh names no helper bazzite-mx-$stem"
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

    for test in "$tests"/[0-9][0-9]-*.sh "$tests"/helpers/*.sh; do
        count=$((count + 1))
        echo "::group:: === test $(basename "$test") ==="

        if ! run_one_test "$test"; then
            failed=1
        fi

        echo "::endgroup::"
    done

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
    local dir output

    dir=$(mktemp -d)
    # shellcheck disable=SC2064  # expand now: the local is gone at EXIT
    trap "rm -rf '$dir'" EXIT
    mkdir -p "$dir/tests/helpers" "$dir/scripts" "$dir/system_files/usr/libexec"

    : > "$dir/scripts/10-a.sh"
    : > "$dir/system_files/usr/libexec/bazzite-mx-a"
    : > "$dir/system_files/usr/libexec/bazzite-mx-c"
    printf '#!/usr/bin/env bash\necho "OK: helper a"\n' > "$dir/tests/helpers/a.sh"
    self_test_write_test "$dir" 'echo "OK: a"'

    output=$(run_tests "$dir/tests" "$dir/scripts" || true)

    if [ "$(tail -n1 <<< "$output")" != "tests: 2 passed" ]; then
        echo "self-test: the known-good layout, a helper without a test in it:" \
            "$(tail -n1 <<< "$output")"
        exit 1
    fi

    self_test_write_test "$dir" 'echo "OK: a"
echo "FAIL: a broke"'
    self_test_expect_refused "$dir" "a FAIL line"

    self_test_write_test "$dir" 'echo "OK: a"
exit 3'
    self_test_expect_refused "$dir" "a non-zero exit"

    self_test_write_test "$dir" 'true'
    self_test_expect_refused "$dir" "a test without an OK: line"

    self_test_write_test "$dir" 'echo "OK: a"'
    : > "$dir/scripts/20-b.sh"
    self_test_expect_refused "$dir" "a build script without a test"
    rm "$dir/scripts/20-b.sh"

    printf '#!/usr/bin/env bash\necho "OK: b"\n' > "$dir/tests/helpers/b.sh"
    self_test_expect_refused "$dir" "a helper test naming no helper"
    rm "$dir/tests/helpers/b.sh"

    printf '#!/usr/bin/env bash\necho "OK: c"\n' > "$dir/tests/30-c.sh"
    self_test_expect_refused "$dir" "a test without a build script"

    echo "self-test ok: 1 good layout of both classes (2 tests counted, a helper without" \
        "its test allowed), 6 bad layouts refused"
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
        echo "run.sh: usage: run.sh [--self-test]" >&2
        exit 1
        ;;
esac
