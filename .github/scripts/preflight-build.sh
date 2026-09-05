#!/usr/bin/env bash
# Runs the local pre-flight: one flavour built with the recipe CI runs, judged
# on the build's own exit status and on the scripts' own output, then probed
# with check-image.sh. It is the one entry point the /preflight command calls.
#
# Usage: preflight-build.sh [<flavour>] [--no-cache]
#          <flavour>   bazzite (default), bazzite-nvidia-open or bazzite-nvidia
#          --no-cache  rebuild every layer; a changed script under build_files/
#                      or system_files/ needs it, the layer cache not seeing a
#                      bind mount (docs/gotchas.md § A local pre-flight can
#                      exit 0 without running a changed build script)
#        preflight-build.sh --self-test
# Output: every name carries the flavour's image, so two flavours coexist:
#   <image>-base.env, <image>-labels.txt and <image>-preflight.log in /var/tmp
#   (/tmp is a tmpfs on the hosts and the log has to outlive a reboot) and the
#   image localhost/<image>:preflight, <image> being bazzite-mx,
#   bazzite-mx-nvidia-open or bazzite-mx-nvidia. On stdout the build's log,
#   `build ok: N scripts ran, N tests passed, exit 0`, the lines of
#   check-image.sh and the closing
#   `preflight ok: <image> <version> <id> (<N> GiB)`.
# Exit status: 0 image built and probed; 1 when an argument is refused, the
#   build fails, the log lacks the scripts' own output or holds a `FAIL:` line,
#   the reason on stderr as `preflight-build: …`; when resolve-base.sh or
#   check-image.sh refuses, its own status and its own `resolve-base: …` or
#   `check-image: …` line.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPTS_DIR/../.." && pwd)
OUTPUT_DIR=/var/tmp

# --- the arguments ------------------------------------------------------------

# parse_args <argument>...: sets FLAVOUR and NO_CACHE in the caller, one flavour
# at most and nothing but --no-cache besides it; status 1 with the reason for
# any other argument or an unknown flavour.
parse_args() {
    local argument

    FLAVOUR=""
    NO_CACHE=""

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

# set_output_names <flavour>: the coords, the labels, the log and the tag, each
# named after the flavour's own image, so a pre-flight of one flavour never
# overwrites another's log nor re-tags its image.
set_output_names() {
    local image

    image=$(image_of "$1")
    COORDS_FILE=$OUTPUT_DIR/$image-base.env
    LABELS_FILE=$OUTPUT_DIR/$image-labels.txt
    LOG_FILE=$OUTPUT_DIR/$image-preflight.log
    IMAGE_TAG=localhost/$image:preflight
}

# --- the verdict on the log ---------------------------------------------------

# judge_log <log>: status 0 with `build ok: …` when the build exited 0 and the
# log carries the scripts' own closing lines and no `FAIL:` line. buildah keys a
# RUN on its command string, never on a bind mount's content, so a cached run
# exits 0 without running anything: the proof that the scripts ran is their
# output, and a log without it is refused as a cached build.
judge_log() {
    local log=$1
    local status scripts_ran tests_passed fail_lines
    local cached="a cached build, rerun with --no-cache"

    status=$(sed -n 's/^BUILD_EXIT=//p' "$log" | tail -n1 || true)

    if [ "$status" != 0 ]; then
        print_error "the build exited $status (see $log)"
        return 1
    fi

    # log() of build_files/lib/log.sh wraps its line in "=== … ===".
    scripts_ran=$(sed -n 's/^=== build\.sh: \([0-9]*\) scripts ran ===$/\1/p' "$log" \
        | tail -n1 || true)
    tests_passed=$(sed -n 's/^tests: \([0-9]*\) passed$/\1/p' "$log" | tail -n1 || true)

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
# base_image and version in the caller.
write_coords_and_labels() {
    local flavour=$1
    local kernel_version revision

    revision=$(git -C "$REPO_ROOT" rev-parse HEAD)
    "$SCRIPTS_DIR/resolve-base.sh" "$flavour" > "$COORDS_FILE"
    image_name=$(sed -n 's/^image_name=//p' "$COORDS_FILE")
    base_image=$(sed -n 's/^base_image=//p' "$COORDS_FILE")
    kernel_version=$(sed -n 's/^kernel_version=//p' "$COORDS_FILE")

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

# preflight <flavour>: coords and labels, the build, the verdict on its log, the
# probe of the image, then the closing `preflight ok:` line; exits 1 on a log
# judged bad.
preflight() {
    local flavour=$1
    local image_name base_image version image_id image_size

    set_output_names "$flavour"
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

# self_test_arguments: what parse_args and set_output_names make of good
# arguments, and the bad ones parse_args refuses.
self_test_arguments() {
    local bad output plain_log

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

    # Known-bad: every flavour wrote bazzite-mx-preflight.log and re-tagged
    # localhost/bazzite-mx:preflight, so one pre-flight erased the other's.
    set_output_names bazzite
    plain_log=$LOG_FILE
    set_output_names bazzite-nvidia

    if [ "$LOG_FILE" = "$plain_log" ]; then
        fail_self_test "two flavours share the log $LOG_FILE"
    fi

    if [ "$IMAGE_TAG" != localhost/bazzite-mx-nvidia:preflight ]; then
        fail_self_test "the tag of bazzite-nvidia is '$IMAGE_TAG'"
    fi

    for bad in bazzite-closed --bogus "bazzite bazzite-nvidia"; do
        REFUSED=$((REFUSED + 1))

        # shellcheck disable=SC2086  # the case with two flavours is split on purpose
        if parse_args $bad > /dev/null 2>&1; then
            fail_self_test "arguments '$bad' accepted"
        fi
    done

    output=$(parse_args --bogus 2>&1 || true)

    if ! grep -q "unknown option" <<< "$output"; then
        fail_self_test "'--bogus' refused for another reason: $output"
    fi
}

# self_test_write_logs <dir>: good.log, a build that ran its scripts and tests,
# and five known-bad logs derived from it or written whole.
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

# self_test_logs <dir>: the good log accepted; the five bad ones refused.
self_test_logs() {
    local dir=$1
    local bad

    self_test_write_logs "$dir"

    if ! judge_log "$dir/good.log" > /dev/null; then
        fail_self_test "a good log refused"
    fi

    for bad in exit1 noscripts notests cached fail; do
        REFUSED_LOGS=$((REFUSED_LOGS + 1))

        if judge_log "$dir/$bad.log" > /dev/null 2>&1; then
            fail_self_test "known-bad log $REFUSED_LOGS ($bad) accepted"
        fi
    done
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
