#!/usr/bin/env bash
# The local pre-flight: one flavour built with the recipe CI runs, judged on
# the build's own exit status and on the scripts' own output, then probed with
# check-image.sh. The one entry point the /preflight command calls.
#
# Usage: preflight-build.sh [<flavour>] [--no-cache]
#          <flavour>    bazzite (default), bazzite-nvidia-open or bazzite-nvidia
#          --no-cache   rebuild every layer; a changed script under build_files/
#                       or system_files/ needs it, the layer cache not seeing a
#                       bind mount (docs/gotchas.md § A local pre-flight can
#                       exit 0 without running a changed build script)
#        preflight-build.sh --self-test
# Environment: NO_CACHE=1 stands for --no-cache; PREFLIGHT_DIR is where the
#   coords, the labels and the log land (default /var/tmp, since /tmp is a
#   tmpfs on the hosts and the log has to outlive a reboot); REPO_ROOT is the
#   checkout to build (default: the one this script sits in).
# Output: bazzite-mx-base.env, bazzite-mx-labels.txt and bazzite-mx-preflight.log
#   in PREFLIGHT_DIR; the image localhost/bazzite-mx:preflight; on stdout the
#   build's log, `build ok: N scripts ran, N tests passed, exit 0`, the lines
#   of check-image.sh and the closing `preflight ok: <image> <version> <id>`.
# Exit status: 0 image built and probed; 1 when an argument is refused, the
#   build fails, the log lacks the scripts' own output or holds a `FAIL:` line,
#   or check-image.sh refuses the image, the reason on stderr as
#   `preflight-build: …`.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=${REPO_ROOT:-$(cd "$SCRIPTS_DIR/../.." && pwd)}
OUTPUT_DIR=${PREFLIGHT_DIR:-/var/tmp}
COORDS_FILE=$OUTPUT_DIR/bazzite-mx-base.env
LABELS_FILE=$OUTPUT_DIR/bazzite-mx-labels.txt
LOG_FILE=$OUTPUT_DIR/bazzite-mx-preflight.log
IMAGE_TAG=localhost/bazzite-mx:preflight

# --- the arguments ------------------------------------------------------------

# parse_args <argument>...: sets FLAVOUR and NO_CACHE in the caller, one
# flavour at most and nothing but --no-cache besides it; status 1 with the
# reason for any other argument or an unknown flavour.
parse_args() {
    local argument

    FLAVOUR=""
    NO_CACHE=${NO_CACHE:-}

    for argument in "$@"; do
        case "$argument" in
            --no-cache)
                NO_CACHE=1
                ;;
            -*)
                print_error "unknown option '$argument'"
                return 1
                ;;
            *)
                if [ -n "$FLAVOUR" ]; then
                    print_error "one flavour at most, got '$FLAVOUR' and '$argument'"
                    return 1
                fi
                FLAVOUR=$argument
                ;;
        esac
    done

    FLAVOUR=${FLAVOUR:-bazzite}
    if ! image_of "$FLAVOUR" > /dev/null; then
        return 1
    fi
}

# --- the verdict on the log ---------------------------------------------------

# judge_log <log>: status 0 with `build ok: …` when the build exited 0 and the
# log carries the scripts' own closing lines and no `FAIL:` line. buildah keys
# a RUN on its command string, never on a bind mount's content, so a cached
# run exits 0 without running anything: the proof that the scripts ran is
# their output, and a log without it is refused as a cached build.
judge_log() {
    local log=$1
    local status scripts_ran tests_passed fail_lines
    local cached="a cached build, rerun with --no-cache"

    if [ ! -f "$log" ]; then
        print_error "log '$log' missing"
        return 1
    fi

    status=$(sed -n 's/^BUILD_EXIT=//p' "$log" | tail -n1)
    if [ -z "$status" ]; then
        print_error "no BUILD_EXIT line in $log: the build did not finish"
        return 1
    fi
    if [ "$status" != 0 ]; then
        print_error "the build exited $status (see $log)"
        return 1
    fi

    # log() of build_files/lib/log.sh wraps its line in "=== … ===".
    scripts_ran=$(sed -n 's/^=== build\.sh: \([0-9]*\) scripts ran ===$/\1/p' "$log" | tail -n1)
    tests_passed=$(sed -n 's/^tests: \([0-9]*\) passed$/\1/p' "$log" | tail -n1)
    if [ -z "$scripts_ran" ]; then
        print_error "no 'build.sh: N scripts ran' line in $log: $cached"
        return 1
    fi
    if [ -z "$tests_passed" ]; then
        print_error "no 'tests: N passed' line in $log: $cached"
        return 1
    fi

    fail_lines=$(grep -c '^FAIL:' "$log" || true)
    if [ "$fail_lines" -ne 0 ]; then
        print_error "$fail_lines FAIL line(s) in $log"
        return 1
    fi

    echo "build ok: $scripts_ran scripts ran, $tests_passed tests passed, exit 0"
}

# --- the build ----------------------------------------------------------------

# write_coords_and_labels <flavour>: resolve-base.sh into COORDS_FILE and
# image-labels.sh, for the checkout's HEAD, into LABELS_FILE; sets image_name,
# base_image and version in the caller and prints them with the kernel.
write_coords_and_labels() {
    local flavour=$1
    local kernel_version revision

    "$SCRIPTS_DIR/resolve-base.sh" "$flavour" > "$COORDS_FILE"
    image_name=$(sed -n 's/^image_name=//p' "$COORDS_FILE")
    base_image=$(sed -n 's/^base_image=//p' "$COORDS_FILE")
    kernel_version=$(sed -n 's/^kernel_version=//p' "$COORDS_FILE")

    revision=$(git -C "$REPO_ROOT" rev-parse HEAD)
    "$SCRIPTS_DIR/image-labels.sh" "$COORDS_FILE" "" "$revision" > "$LABELS_FILE"
    version=$(sed -n 's/^org\.opencontainers\.image\.version=//p' "$LABELS_FILE")

    echo "base_image=$base_image kernel_version=$kernel_version version=$version"
}

# run_build <image name> <base image> <version>: podman build of the checkout
# with every label of LABELS_FILE, the output on stdout and in LOG_FILE, the
# build's own exit status appended to the log as its BUILD_EXIT line.
run_build() {
    local image_name=$1
    local base_image=$2
    local version=$3
    local -a build_args=(--pull=newer)
    local -a label_args
    local status

    if [ -n "$NO_CACHE" ]; then
        build_args+=(--no-cache)
    fi
    mapfile -t label_args < <(sed 's/^/--label=/' "$LABELS_FILE")

    # The build's exit status is read from PIPESTATUS, not tee's, and a failed
    # build must reach the BUILD_EXIT line instead of stopping the script here.
    set +e
    podman build "${build_args[@]}" \
        --build-arg BASE_IMAGE="$base_image" \
        --build-arg IMAGE_NAME="$image_name" \
        --build-arg VERSION="$version" \
        "${label_args[@]}" \
        --tag "$IMAGE_TAG" "$REPO_ROOT" 2>&1 | tee "$LOG_FILE"
    status=${PIPESTATUS[0]}
    set -e

    echo "BUILD_EXIT=$status" >> "$LOG_FILE"
}

# preflight <flavour>: coords and labels, the build, the verdict on its log,
# the probe of the image, then the closing `preflight ok:` line.
preflight() {
    local flavour=$1
    local image_name base_image version image_id image_size

    write_coords_and_labels "$flavour"
    run_build "$image_name" "$base_image" "$version"

    if ! judge_log "$LOG_FILE"; then
        exit 1
    fi
    "$SCRIPTS_DIR/check-image.sh" "$IMAGE_TAG" "$LABELS_FILE"

    image_id=$(podman image inspect --format '{{.Id}}' "$IMAGE_TAG")
    image_size=$(podman image inspect --format '{{.Size}}' "$IMAGE_TAG")
    echo "preflight ok: $image_name $version ${image_id:0:12}" \
        "($((image_size / 1024 / 1024 / 1024)) GiB)"
}

# --- self-test ----------------------------------------------------------------

REFUSED_LOGS=0

SELF_TEST_RUN_STEP='[3/3] STEP 4/6: RUN --mount=type=bind,from=ctx,source=/,target=/ctx'
SELF_TEST_RUN_STEP+=' /ctx/build_files/build.sh'

# self_test_arguments: the defaults, a flavour with --no-cache, then an
# unknown flavour, an unknown option and two flavours refused, the option for
# its own reason.
self_test_arguments() {
    local bad output

    NO_CACHE=''
    if ! parse_args > /dev/null; then
        fail_self_test "no arguments refused"
    fi
    if [ "$FLAVOUR" != bazzite ] || [ -n "$NO_CACHE" ]; then
        fail_self_test "defaults are '$FLAVOUR' and NO_CACHE='$NO_CACHE'"
    fi

    if ! parse_args bazzite-nvidia --no-cache > /dev/null; then
        fail_self_test "'bazzite-nvidia --no-cache' refused"
    fi
    if [ "$FLAVOUR" != bazzite-nvidia ] || [ "$NO_CACHE" != 1 ]; then
        fail_self_test "'--no-cache' not read"
    fi

    for bad in bazzite-closed --bogus "bazzite bazzite-nvidia"; do
        REFUSED=$((REFUSED + 1))
        # shellcheck disable=SC2086  # the case with two flavours is split on purpose
        if parse_args $bad > /dev/null 2>&1; then
            fail_self_test "arguments '$bad' accepted"
        fi
    done

    # Each refusal for its own reason, so a guard another one masks still counts.
    output=$(parse_args --bogus 2>&1 || true)
    if ! grep -q "unknown option" <<< "$output"; then
        fail_self_test "'--bogus' refused for another reason: $output"
    fi
}

# self_test_write_logs <dir>: good.log, a build that ran its scripts and
# tests, and seven known-bad logs derived from it or written whole.
self_test_write_logs() {
    local dir=$1
    local fail_line='FAIL: 70-justfile.sh: verify-host exited 1'

    printf '%s\n' \
        "$SELF_TEST_RUN_STEP" \
        '=== build.sh: 20 scripts ran ===' \
        'OK: 90-validate-repos.sh: 3 repo files valid' \
        'tests: 20 passed' \
        'COMMIT localhost/bazzite-mx:preflight' \
        'BUILD_EXIT=0' > "$dir/good.log"

    sed '/^BUILD_EXIT=/d' "$dir/good.log" > "$dir/noexit.log"
    sed '/^=== build\.sh:/d' "$dir/good.log" > "$dir/noscripts.log"
    sed '/^tests:/d' "$dir/good.log" > "$dir/notests.log"
    sed 's/^BUILD_EXIT=0/BUILD_EXIT=1/' "$dir/good.log" > "$dir/exit1.log"
    sed "s/^tests: 20 passed/$fail_line\ntests: 19 passed/" "$dir/good.log" > "$dir/fail.log"

    printf '%s\n' \
        "$SELF_TEST_RUN_STEP" \
        '--> Using cache 2f6496a5be2f' \
        'COMMIT localhost/bazzite-mx:preflight' \
        'BUILD_EXIT=0' > "$dir/cached.log"
}

# self_test_logs <dir>: the good log accepted; the absent log and the six bad
# ones refused, the absent one and the one without BUILD_EXIT each for its own
# reason.
self_test_logs() {
    local dir=$1
    local bad output

    self_test_write_logs "$dir"
    if ! judge_log "$dir/good.log" > /dev/null; then
        fail_self_test "a good log refused"
    fi

    for bad in absent noexit exit1 noscripts notests cached fail; do
        REFUSED_LOGS=$((REFUSED_LOGS + 1))
        if judge_log "$dir/$bad.log" > /dev/null 2>&1; then
            fail_self_test "known-bad log $REFUSED_LOGS ($bad) accepted"
        fi
    done

    output=$(judge_log "$dir/absent.log" 2>&1 || true)
    if ! grep -q "missing" <<< "$output"; then
        fail_self_test "an absent log refused for another reason: $output"
    fi

    output=$(judge_log "$dir/noexit.log" 2>&1 || true)
    if ! grep -q "no BUILD_EXIT" <<< "$output"; then
        fail_self_test "a log without BUILD_EXIT refused for another reason: $output"
    fi
}

self_test() {
    local dir

    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN

    self_test_arguments
    self_test_logs "$dir"

    echo "self-test ok: good arguments and a good log accepted," \
        "$REFUSED bad arguments and $REFUSED_LOGS bad logs refused"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    *)
        if ! parse_args "$@"; then
            exit 1
        fi
        preflight "$FLAVOUR"
        ;;
esac
