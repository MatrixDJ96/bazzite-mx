#!/usr/bin/env bash
# The local pre-flight: one flavour built with the recipe CI runs, judged on
# the build's own exit status and on the scripts' own output, then probed
# with check-image.sh. The one entry point /preflight calls.
#
#   preflight-build.sh [<flavour>] [--no-cache]   bazzite (default) | bazzite-nvidia-open | bazzite-nvidia
#       --no-cache, or NO_CACHE=1: a changed script under build_files/ or
#       system_files/ needs it, the layer cache not seeing a bind mount
#   preflight-build.sh --self-test
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# The checkout the build context and the revision come from, whatever the cwd.
REPO_ROOT=${REPO_ROOT:-$(cd "$SCRIPTS/../.." && pwd)}
# /tmp is a tmpfs on the hosts; the log outlives a reboot here.
DIR=${PREFLIGHT_DIR:-/var/tmp}
ENV_FILE=$DIR/bazzite-mx-base.env
LABELS=$DIR/bazzite-mx-labels.txt
LOG=$DIR/bazzite-mx-preflight.log
TAG=localhost/bazzite-mx:preflight

# parse_args sets FLAVOUR and NO_CACHE in the caller; one flavour at most,
# nothing but --no-cache besides it.
parse_args() {
    FLAVOUR=""
    NO_CACHE=${NO_CACHE:-}
    local arg
    for arg in "$@"; do
        case "$arg" in
            --no-cache) NO_CACHE=1 ;;
            -*) err "unknown option '$arg'" || return 1 ;;
            *)
                [ -z "$FLAVOUR" ] || err "one flavour at most, got '$FLAVOUR' and '$arg'" || return 1
                FLAVOUR=$arg
                ;;
        esac
    done
    FLAVOUR=${FLAVOUR:-bazzite}
    image_of "$FLAVOUR" > /dev/null || return 1
}

# judge_log <log>: the build's own exit status and its own output. buildah
# keys a RUN on its command string, never on a bind mount's content, so a
# cached run exits 0 without running anything: the proof that the scripts ran
# is their output, and a log without it is refused (docs/gotchas.md).
judge_log() {
    local log=$1 status scripts tests fails
    [ -f "$log" ] || err "log '$log' missing" || return 1
    status=$(sed -n 's/^BUILD_EXIT=//p' "$log" | tail -n1)
    [ -n "$status" ] || err "no BUILD_EXIT line in $log: the build did not finish" || return 1
    [ "$status" = 0 ] || err "the build exited $status (see $log)" || return 1
    # log() of build_files/lib/log.sh wraps its line in "=== ... ===".
    scripts=$(sed -n 's/^=== build\.sh: \([0-9]*\) scripts ran ===$/\1/p' "$log" | tail -n1)
    tests=$(sed -n 's/^tests: \([0-9]*\) passed$/\1/p' "$log" | tail -n1)
    [ -n "$scripts" ] || err "no 'build.sh: N scripts ran' line in $log: a cached build, rerun with --no-cache" || return 1
    [ -n "$tests" ] || err "no 'tests: N passed' line in $log: a cached build, rerun with --no-cache" || return 1
    fails=$(grep -c '^FAIL:' "$log" || true)
    [ "$fails" -eq 0 ] || err "$fails FAIL line(s) in $log" || return 1
    echo "build ok: $scripts scripts ran, $tests tests passed, exit 0"
}

build() {
    local flavour=$1 image_name base_image kernel_version version id size
    local -a args=(--pull=newer) label_args
    "$SCRIPTS/resolve-base.sh" "$flavour" > "$ENV_FILE"
    image_name=$(sed -n 's/^image_name=//p' "$ENV_FILE")
    base_image=$(sed -n 's/^base_image=//p' "$ENV_FILE")
    kernel_version=$(sed -n 's/^kernel_version=//p' "$ENV_FILE")
    "$SCRIPTS/image-labels.sh" "$ENV_FILE" "" "$(git -C "$REPO_ROOT" rev-parse HEAD)" > "$LABELS"
    version=$(sed -n 's/^org\.opencontainers\.image\.version=//p' "$LABELS")
    echo "base_image=$base_image kernel_version=$kernel_version version=$version"
    [ -z "$NO_CACHE" ] || args+=(--no-cache)
    mapfile -t label_args < <(sed 's/^/--label=/' "$LABELS")
    # The build's own exit status, not tee's.
    set +e
    podman build "${args[@]}" \
        --build-arg BASE_IMAGE="$base_image" \
        --build-arg IMAGE_NAME="$image_name" \
        --build-arg VERSION="$version" \
        "${label_args[@]}" \
        --tag "$TAG" "$REPO_ROOT" 2>&1 | tee "$LOG"
    local status=${PIPESTATUS[0]}
    set -e
    echo "BUILD_EXIT=$status" >> "$LOG"
    judge_log "$LOG"
    "$SCRIPTS/check-image.sh" "$TAG" "$LABELS"
    id=$(podman image inspect --format '{{.Id}}' "$TAG")
    size=$(podman image inspect --format '{{.Size}}' "$TAG")
    echo "preflight ok: $image_name $version ${id:0:12} ($((size / 1024 / 1024 / 1024)) GiB)"
}

self_test() {
    local dir out n=0
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    NO_CACHE=''
    parse_args > /dev/null || fail "self-test: no arguments refused"
    [ "$FLAVOUR" = bazzite ] && [ -z "$NO_CACHE" ] || fail "self-test: defaults are '$FLAVOUR' and NO_CACHE='$NO_CACHE'"
    parse_args bazzite-nvidia --no-cache > /dev/null || fail "self-test: 'bazzite-nvidia --no-cache' refused"
    [ "$FLAVOUR" = bazzite-nvidia ] && [ "$NO_CACHE" = 1 ] || fail "self-test: '--no-cache' not read"
    for bad in bazzite-closed --bogus "bazzite bazzite-nvidia"; do
        # shellcheck disable=SC2086
        if parse_args $bad > /dev/null 2>&1; then
            fail "self-test: arguments '$bad' accepted"
        fi
    done
    # Each refusal for its own reason, so a guard another one masks still counts.
    out=$(parse_args --bogus 2>&1 || true)
    grep -q "unknown option" <<< "$out" || fail "self-test: '--bogus' refused for another reason: $out"
    printf '%s\n' \
        '[3/3] STEP 4/6: RUN --mount=type=bind,from=ctx,source=/,target=/ctx /ctx/build_files/build.sh' \
        '=== build.sh: 20 scripts ran ===' \
        'OK: 90-validate-repos.sh: 3 repo files valid' \
        'tests: 20 passed' \
        'COMMIT localhost/bazzite-mx:preflight' \
        'BUILD_EXIT=0' > "$dir/good.log"
    judge_log "$dir/good.log" > /dev/null || fail "self-test: a good log refused"
    sed '/^BUILD_EXIT=/d' "$dir/good.log" > "$dir/noexit.log"
    sed '/^=== build\.sh:/d' "$dir/good.log" > "$dir/noscripts.log"
    sed '/^tests:/d' "$dir/good.log" > "$dir/notests.log"
    sed 's/^BUILD_EXIT=0/BUILD_EXIT=1/' "$dir/good.log" > "$dir/exit1.log"
    printf '%s\n' \
        '[3/3] STEP 4/6: RUN --mount=type=bind,from=ctx,source=/,target=/ctx /ctx/build_files/build.sh' \
        '--> Using cache 2f6496a5be2f' \
        'COMMIT localhost/bazzite-mx:preflight' \
        'BUILD_EXIT=0' > "$dir/cached.log"
    sed 's/^tests: 20 passed/FAIL: 70-justfile.sh: verify-host exited 1\ntests: 19 passed/' "$dir/good.log" > "$dir/fail.log"
    for bad in absent noexit exit1 noscripts notests cached fail; do
        n=$((n + 1))
        if judge_log "$dir/$bad.log" > /dev/null 2>&1; then
            fail "self-test: known-bad log $n ($bad) accepted"
        fi
    done
    out=$(judge_log "$dir/absent.log" 2>&1 || true)
    grep -q "missing" <<< "$out" || fail "self-test: an absent log refused for another reason: $out"
    out=$(judge_log "$dir/noexit.log" 2>&1 || true)
    grep -q "no BUILD_EXIT" <<< "$out" || fail "self-test: a log without BUILD_EXIT refused for another reason: $out"
    echo "self-test ok: good arguments and a good log accepted, 3 bad arguments and $n bad logs refused"
}

case "${1:-}" in
    --self-test) self_test ;;
    *)
        parse_args "$@" || exit 1
        build "$FLAVOUR"
        ;;
esac
