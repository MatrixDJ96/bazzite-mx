#!/usr/bin/env bash
# Smoke test runner, the second RUN of the Containerfile: offline, on the tree
# clean-stage left. A test prints `OK:` and `FAIL:` lines; any FAIL line, any
# non-zero exit and any unpaired script or test fails the build.
set -euo pipefail

TESTS_DIR=$(dirname "$(realpath "$0")")
BUILD_FILES=$(realpath "$TESTS_DIR/..")
export BUILD_STATE=/usr/lib/bazzite-mx/build-state

# run_tests <tests-dir> <build-files-dir>
run_tests() {
    local tests=$1 scripts=$2 t s stem failed=0 out n=0
    # Pairing guard, both directions: a feature cannot land without its test.
    for s in "$scripts"/[0-9][0-9]-*.sh; do
        [ -e "$s" ] || continue
        stem=$(basename "$s")
        [ -f "$tests/$stem" ] || {
            echo "FAIL: build script $stem has no test tests/$stem"
            failed=1
        }
    done
    for t in "$tests"/[0-9][0-9]-*.sh; do
        [ -e "$t" ] || continue
        stem=$(basename "$t")
        [ -f "$scripts/$stem" ] || {
            echo "FAIL: test $stem has no build script $stem"
            failed=1
        }
    done
    for t in "$tests"/[0-9][0-9]-*.sh; do
        [ -e "$t" ] || continue
        n=$((n + 1))
        echo "::group:: === test $(basename "$t") ==="
        if out=$(bash "$t" 2>&1); then
            printf '%s\n' "$out"
            if grep -q '^FAIL:' <<< "$out"; then
                echo "test $(basename "$t"): FAIL lines above"
                failed=1
            elif ! grep -q '^OK:' <<< "$out"; then
                echo "FAIL: test $(basename "$t") printed no OK: line"
                failed=1
            fi
        else
            printf '%s\n' "$out"
            echo "FAIL: test $(basename "$t") exited non-zero"
            failed=1
        fi
        echo "::endgroup::"
    done
    [ "$n" -gt 0 ] || {
        echo "FAIL: no tests found under $tests"
        failed=1
    }
    if [ "$failed" -ne 0 ]; then
        echo "tests: FAILED"
        return 1
    fi
    echo "tests: $n passed"
}

self_test() {
    local d
    d=$(mktemp -d)
    # shellcheck disable=SC2064  # expand now: the local is gone at EXIT
    trap "rm -rf '$d'" EXIT
    mkdir -p "$d/tests" "$d/scripts"
    : > "$d/scripts/10-a.sh"
    printf '#!/usr/bin/env bash\necho "OK: a"\n' > "$d/tests/10-a.sh"
    run_tests "$d/tests" "$d/scripts" > /dev/null || {
        echo "self-test: the known-good pair fails"
        exit 1
    }
    printf '#!/usr/bin/env bash\necho "OK: a"\necho "FAIL: a broke"\n' > "$d/tests/10-a.sh"
    if run_tests "$d/tests" "$d/scripts" > /dev/null; then
        echo "self-test: a FAIL line passed"
        exit 1
    fi
    printf '#!/usr/bin/env bash\nexit 3\n' > "$d/tests/10-a.sh"
    if run_tests "$d/tests" "$d/scripts" > /dev/null; then
        echo "self-test: a non-zero exit passed"
        exit 1
    fi
    printf '#!/usr/bin/env bash\necho "OK: a"\n' > "$d/tests/10-a.sh"
    : > "$d/scripts/20-b.sh"
    if run_tests "$d/tests" "$d/scripts" > /dev/null; then
        echo "self-test: a build script without a test passed"
        exit 1
    fi
    rm "$d/scripts/20-b.sh"
    printf '#!/usr/bin/env bash\necho "OK: c"\n' > "$d/tests/30-c.sh"
    if run_tests "$d/tests" "$d/scripts" > /dev/null; then
        echo "self-test: a test without a build script passed"
        exit 1
    fi
    echo "self-test ok: 1 good layout, 4 bad layouts refused"
}

case "${1:-}" in
    --self-test) self_test ;;
    "") run_tests "$TESTS_DIR" "$BUILD_FILES" ;;
    *)
        echo "usage: run.sh [--self-test]" >&2
        exit 1
        ;;
esac
