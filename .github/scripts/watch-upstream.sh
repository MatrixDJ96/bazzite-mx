#!/usr/bin/env bash
# The upstream watcher: for each flavour, the base's live digest against the
# base.digest label our own :stable carries, then whether to dispatch a
# release. The digest and not the version, because a retag or a `.N` rebuild
# upstream moves one and leaves the other. It fails closed: an unreadable base
# or image, or a :stable without the label, is UNKNOWN and exits 1, so the run
# goes red instead of dispatching.
#
# Usage: watch-upstream.sh check
#          one line per flavour, then verdict=current|stale|absent and
#          reason=upstream:<12 hex per base digest, joined by +>
#        watch-upstream.sh decide --verdict <v> --reason <r> --promote-var <value>
#                                 [--dry-run]
#          dispatch=true|false. A dispatch needs a stale verdict, PROMOTE_STABLE
#          set to "true", no release run open and none started with the same
#          reason inside COALESCE_HOURS
#          --dry-run           say what would be dispatched, dispatch=false
#        watch-upstream.sh --self-test
# Needs skopeo (logged in to ghcr.io), gh (GH_TOKEN), jq and resolve-base.sh
# beside this script.
# Output: the lines above on stdout; verdict, reason and dispatch also in
#   GITHUB_OUTPUT when a workflow set it.
# Exit status: 0 verdict or decision written; 1 when an argument is refused, a
#   base or image cannot be read, :stable lacks the label or the release runs
#   cannot be read, the reason on stderr as `watch-upstream: …`.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

OUR_TAG=stable
RELEASE_WORKFLOW=.github/workflows/release.yml
RUN_NAME_PREFIX="Release: "
COALESCE_HOURS=24
OURS_ERROR_FILE=$(mktemp)
RUNS_ERROR_FILE=$(mktemp)
trap 'rm -f "$OURS_ERROR_FILE" "$RUNS_ERROR_FILE"' EXIT
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# --- the readings -------------------------------------------------------------

# base_coords <flavour> <fixture dir>: the coords of the flavour's base, from
# resolve-base.sh or from the fixture. GITHUB_OUTPUT is unset for the live call
# so resolve-base.sh's keys do not become outputs of this step.
base_coords() {
    local flavour=$1
    local dir=$2

    if [ -n "$dir" ]; then
        if [ ! -f "$dir/base-$flavour.env" ] || [ ! -r "$dir/base-$flavour.env" ]; then
            print_error "fixture $dir/base-$flavour.env missing or unreadable"
            return 1
        fi

        cat "$dir/base-$flavour.env"
        return 0
    fi

    env -u GITHUB_OUTPUT "$SCRIPT_DIR/resolve-base.sh" "$flavour"
}

# ours_inspect <image> <fixture dir>: the `skopeo inspect` of our image's
# :stable, from the registry or from the fixture; status 2 when the image is
# absent, 1 on any other failure.
ours_inspect() {
    local image=$1
    local dir=$2
    local manifest error

    if [ -n "$dir" ]; then
        if [ -f "$dir/ours-$image.absent" ]; then
            return 2
        fi

        if [ ! -f "$dir/ours-$image.json" ] || [ ! -r "$dir/ours-$image.json" ]; then
            print_error "fixture $dir/ours-$image.json missing or unreadable"
            return 1
        fi

        cat "$dir/ours-$image.json"
        return 0
    fi

    if manifest=$(skopeo inspect --retry-times 3 --no-tags \
        "docker://${REGISTRY}/${image}:${OUR_TAG}" 2> "$OURS_ERROR_FILE"); then
        echo "$manifest"
        return 0
    fi

    error=$(< "$OURS_ERROR_FILE")

    if absent_error "$error"; then
        return 2
    fi

    print_error "cannot inspect ${REGISTRY}/${image}:${OUR_TAG}: ${error//$'\n'/ }"
    return 1
}

# --- the verdict --------------------------------------------------------------

# read_base <flavour> <fixture dir>: sets image_name and base_digest in the
# caller from the flavour's base coords; status 1 with the UNKNOWN reason when
# they cannot be read.
read_base() {
    local flavour=$1
    local dir=$2
    local coords

    if ! coords=$(base_coords "$flavour" "$dir"); then
        print_error "cannot resolve ghcr.io/ublue-os/$flavour:stable: UNKNOWN, no dispatch"
        return 1
    fi

    image_name=$(sed -n 's/^image_name=//p' <<< "$coords")
    base_digest=$(sed -n 's/^base_digest=//p' <<< "$coords")
}

# compare_flavour <flavour> <image name> <base digest> <fixture dir>: prints
# the flavour's line and sets flavour_state to current, stale or absent in the
# caller; status 1 with the UNKNOWN reason when our image cannot be read or
# carries no base.digest label.
compare_flavour() {
    local flavour=$1
    local image_name=$2
    local base_digest=$3
    local dir=$4
    local manifest label status

    if manifest=$(ours_inspect "$image_name" "$dir"); then
        status=0
    else
        status=$?
    fi

    if [ "$status" -eq 2 ]; then
        echo "${image_name}:${OUR_TAG} absent: nothing to compare"
        flavour_state=absent
        return 0
    fi

    if [ "$status" -ne 0 ]; then
        print_error "cannot inspect ${REGISTRY}/${image_name}:${OUR_TAG}: UNKNOWN, no dispatch"
        return 1
    fi

    label=$(jq -r '.Labels["org.opencontainers.image.base.digest"] // empty' <<< "$manifest")

    if [[ ! "$label" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        print_error "${image_name}:${OUR_TAG} carries no org.opencontainers.image.base.digest" \
            "label: UNKNOWN, no dispatch (a release restores it)"
        return 1
    fi

    if [ "$label" = "$base_digest" ]; then
        echo "${image_name}:${OUR_TAG} current: built on $base_digest"
        flavour_state=current
    else
        echo "${image_name}:${OUR_TAG} stale: built on $label," \
            "$flavour:stable is now $base_digest"
        flavour_state=stale
    fi
}

# check <fixture dir>: one line per flavour, then the verdict (stale when any
# flavour is, absent when every one is, current otherwise) and the reason
# built from the three base digests; status 1 on the first UNKNOWN flavour.
check() {
    local dir=$1
    local flavour image_name base_digest flavour_state verdict
    local stale=0 absent=0 total=0 short_digests=""

    for flavour in $FLAVOURS; do
        total=$((total + 1))

        if ! read_base "$flavour" "$dir"; then
            return 1
        fi

        short_digests="${short_digests:+$short_digests+}${base_digest:7:12}"

        if ! compare_flavour "$flavour" "$image_name" "$base_digest" "$dir"; then
            return 1
        fi

        case "$flavour_state" in
            stale)
                stale=$((stale + 1))
                ;;
            absent)
                absent=$((absent + 1))
                ;;
        esac
    done

    if [ "$stale" -gt 0 ]; then
        verdict=stale
    elif [ "$absent" -eq "$total" ]; then
        verdict=absent
    else
        verdict=current
    fi

    emit "verdict=$verdict"
    emit "reason=upstream:$short_digests"
}

# --- the decision -------------------------------------------------------------

# runs_page <gh api filter>...: one page of the repository's runs on stdout;
# status 1 with gh's reason on one `watch-upstream:` line when the read fails.
runs_page() {
    local page error

    if ! page=$(gh api --method GET "repos/$REPO/actions/runs" "$@" -F per_page=100 \
        2> "$RUNS_ERROR_FILE"); then
        error=$(< "$RUNS_ERROR_FILE")
        error=${error//$'\n'/ }
        print_error "cannot read the runs of $REPO: ${error:-no output from gh}"
        return 1
    fi

    echo "$page"
}

# runs_live: the release workflow's runs of the last COALESCE_HOURS plus every
# queued and running one, as one JSON array; status 1 when any of the three
# reads fails, because an empty reading is never "no runs". Filtered by the
# workflow's path: the per-workflow endpoint answers 404 while the file is not
# on the default branch (docs/gotchas.md § A workflow that is not on the
# default branch has no runs endpoint).
runs_live() {
    local since recent queued running

    since=$(date -u -d "-${COALESCE_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)

    if ! recent=$(runs_page -f event=workflow_dispatch -f "created=>=$since"); then
        return 1
    fi

    if ! queued=$(runs_page -f status=queued); then
        return 1
    fi

    if ! running=$(runs_page -f status=in_progress); then
        return 1
    fi

    jq -s --arg path "$RELEASE_WORKFLOW" \
        '[.[].workflow_runs[] | select(.path == $path)
          | {id, display_title, status, conclusion, created_at}] | unique' \
        <<< "$recent$queued$running"
}

# open_runs <runs json>: how many runs are queued, waiting or in progress.
open_runs() {
    local runs=$1
    local open='["queued", "in_progress", "waiting", "pending", "requested"]'

    jq -r --argjson open "$open" '[.[] | select(.status as $s | $open | index($s))] | length' \
        <<< "$runs"
}

# same_reason_runs <runs json> <reason>: how many finished runs with that
# reason in their name were started inside COALESCE_HOURS, whatever their
# conclusion. The window is on the start, so it spaces the dispatches of one
# reason however long a run then waits for a runner; a run still open is the
# check before this one.
same_reason_runs() {
    local runs=$1
    local reason=$2
    local since

    since=$(date -u -d "-${COALESCE_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)
    jq -r --arg title "${RUN_NAME_PREFIX}${reason}" --arg since "$since" \
        '[.[] | select(.display_title == $title and .status == "completed"
                       and .created_at >= $since)] | length' <<< "$runs"
}

# decide <verdict> <reason> <promote var> <runs json> <dry run>: the decision
# line and dispatch=true|false.
decide() {
    local verdict=$1
    local reason=$2
    local promote=$3
    local runs=$4
    local dry_run=$5
    local open same

    if [ "$verdict" != stale ]; then
        echo "verdict $verdict: no dispatch"
        emit dispatch=false
        return 0
    fi

    if [ "$promote" != true ]; then
        echo "promotion switched off (repository variable PROMOTE_STABLE='${promote}'," \
            "not 'true'): a release the gate cannot promote is not created; no dispatch"
        emit dispatch=false
        return 0
    fi

    open=$(open_runs "$runs")

    if [ "$open" -gt 0 ]; then
        echo "$open release run(s) queued or in progress: no dispatch"
        emit dispatch=false
        return 0
    fi

    same=$(same_reason_runs "$runs" "$reason")

    if [ "$same" -gt 0 ]; then
        echo "a release with reason '$reason' started in the last ${COALESCE_HOURS} h" \
            "and has finished: no dispatch"
        emit dispatch=false
        return 0
    fi

    if [ "$dry_run" = true ]; then
        echo "dry run: would dispatch release.yml with reason '$reason' and promote_stable=true"
        emit dispatch=false
        return 0
    fi

    echo "dispatch release.yml with reason '$reason' and promote_stable=true"
    emit dispatch=true
}

# --- the commands -------------------------------------------------------------

# run_decide <argument>...: the decide subcommand's options, the runs read
# live (only when a dispatch is still possible), then decide.
run_decide() {
    local verdict="" reason="" promote="" dry_run=false runs

    while [ $# -gt 0 ]; do
        case "$1" in
            --verdict)
                require_option_value "$1" "${2:-}"
                verdict=$2
                shift 2
                ;;
            --reason)
                require_option_value "$1" "${2:-}"
                reason=$2
                shift 2
                ;;
            --promote-var)
                # Empty when the repository variable is unset: the workflow
                # passes it as it is, and empty is "not true".
                promote=${2:-}
                shift 2
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            *)
                exit_with_error "usage: decide --verdict <v> --reason <r> --promote-var <value>" \
                    "[--dry-run]"
                ;;
        esac
    done

    if [ "$verdict" = stale ] && [ "$promote" = true ]; then
        if ! runs=$(runs_live); then
            exit_with_error "cannot list the runs of $REPO: no dispatch"
        fi
    else
        runs='[]'
    fi

    decide "$verdict" "$reason" "$promote" "$runs" "$dry_run"
}

# --- self-test ----------------------------------------------------------------

SELF_TEST_DIGEST_A=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76
SELF_TEST_DIGEST_B=sha256:c765d566dfbdbdc97808c5b6a00ba0f1b9a5295547490c4b01e1c2ddecf24060
SELF_TEST_DIGEST_C=sha256:ca1d0b10df80ac8c6e60b8a3b0b7f0b6d4b2a1c9e8f7d6c5b4a3928170605040
SELF_TEST_DIGEST_NEW=sha256:1111111111111111111111111111111111111111111111111111111111111111

# self_test_write_ours <file> <base digest>: the inspect of one of our images
# built on that base.
self_test_write_ours() {
    local file=$1
    local base_digest=$2

    printf '{"Digest":"sha256:%064d","Labels":{"org.opencontainers.image.base.digest":"%s"}}\n' \
        0 "$base_digest" > "$file"
}

# self_test_write_fixtures <dir>: the three bases and our three images, each
# built on its base.
self_test_write_fixtures() {
    local dir=$1

    printf 'image_name=bazzite-mx\nbase_digest=%s\n' "$SELF_TEST_DIGEST_A" \
        > "$dir/base-bazzite.env"
    printf 'image_name=bazzite-mx-nvidia-open\nbase_digest=%s\n' "$SELF_TEST_DIGEST_B" \
        > "$dir/base-bazzite-nvidia-open.env"
    printf 'image_name=bazzite-mx-nvidia\nbase_digest=%s\n' "$SELF_TEST_DIGEST_C" \
        > "$dir/base-bazzite-nvidia.env"

    self_test_write_ours "$dir/ours-bazzite-mx.json" "$SELF_TEST_DIGEST_A"
    self_test_write_ours "$dir/ours-bazzite-mx-nvidia-open.json" "$SELF_TEST_DIGEST_B"
    self_test_write_ours "$dir/ours-bazzite-mx-nvidia.json" "$SELF_TEST_DIGEST_C"
}

# self_test_expect_check <dir> <pattern> <what> <failure>: check on the
# fixtures succeeds (or the self-test fails with <failure>) and its output
# holds a line matching the pattern (or it fails with <what>).
self_test_expect_check() {
    local dir=$1
    local pattern=$2
    local what=$3
    local failure=$4
    local output

    if ! output=$(check "$dir"); then
        fail_self_test "check failed $failure"
    fi

    if ! grep -qE "$pattern" <<< "$output"; then
        fail_self_test "$what: $output"
    fi
}

# self_test_verdicts <dir>: current images give current and the reason from
# the three base digests; one stale image gives stale with its line; one
# absent image still gives current; three absent images give absent.
self_test_verdicts() {
    local dir=$1

    self_test_expect_check "$dir" '^verdict=current$' \
        "current images not reported current" "on current images"
    self_test_expect_check "$dir" '^reason=upstream:9556db65991d\+c765d566dfbd\+ca1d0b10df80$' \
        "reason not derived from the base digests" "on current images"

    self_test_write_ours "$dir/ours-bazzite-mx.json" "$SELF_TEST_DIGEST_NEW"
    self_test_expect_check "$dir" '^verdict=stale$' \
        "stale image not reported stale" "on a stale image"
    self_test_expect_check "$dir" '^bazzite-mx:stable stale: ' \
        "stale line missing" "on a stale image"

    rm "$dir/ours-bazzite-mx.json"
    : > "$dir/ours-bazzite-mx.absent"
    self_test_expect_check "$dir" '^verdict=current$' \
        "absent+current not reported current" "with one absent image"

    : > "$dir/ours-bazzite-mx-nvidia-open.absent"
    : > "$dir/ours-bazzite-mx-nvidia.absent"
    rm "$dir/ours-bazzite-mx-nvidia-open.json" "$dir/ours-bazzite-mx-nvidia.json"
    self_test_expect_check "$dir" '^verdict=absent$' \
        "three absent images not reported absent" "with every image absent"
}

# self_test_inspect_retry_note <dir>: a skopeo that retried and then succeeded
# gives the manifest alone, its note on neither channel, and the flavour still
# reads current.
self_test_inspect_retry_note() {
    local dir=$1
    local retry_manifest=$dir/retry.json
    local error_file=$dir/retry.err
    local verdict_file=$dir/retry.out
    local flavour_state=""
    local expected output

    self_test_write_ours "$retry_manifest" "$SELF_TEST_DIGEST_A"
    expected=$(cat "$retry_manifest")

    skopeo() {
        echo 'WARN retrying (1/3)' >&2
        cat "$retry_manifest"
    }

    if ! output=$(ours_inspect bazzite-mx "" 2> "$error_file"); then
        fail_self_test "a skopeo that retried and succeeded was read as a failure"
    fi

    if [ "$output" != "$expected" ]; then
        fail_self_test "the retry note reached the manifest: ${output//$'\n'/ }"
    fi

    if [ -s "$error_file" ]; then
        fail_self_test "the retry note reached stderr: $(< "$error_file")"
    fi

    if ! compare_flavour bazzite bazzite-mx "$SELF_TEST_DIGEST_A" "" > "$verdict_file" 2>&1 \
        || [ "$flavour_state" != current ] \
        || [ "$(grep -c '' "$verdict_file")" -ne 1 ]; then
        fail_self_test "a retried inspect gave no clean verdict:" \
            "$(tr '\n' ' ' < "$verdict_file")"
    fi

    unset -f skopeo
}

# self_test_bad_inputs <dir>: the reads of our image and of its base that
# fail, each refused with its own reason or status.
self_test_bad_inputs() {
    local dir=$1
    local bad output status reason

    rm "$dir/ours-bazzite-mx.absent" "$dir/ours-bazzite-mx-nvidia-open.absent" \
        "$dir/ours-bazzite-mx-nvidia.absent"
    self_test_write_ours "$dir/ours-bazzite-mx-nvidia-open.json" "$SELF_TEST_DIGEST_B"
    self_test_write_ours "$dir/ours-bazzite-mx-nvidia.json" "$SELF_TEST_DIGEST_C"
    echo '{"Digest":"sha256:x","Labels":{"org.opencontainers.image.version":"44.20260902"}}' \
        > "$dir/ours-bazzite-mx.json"

    for bad in label inspect base; do
        REFUSED=$((REFUSED + 1))
        case "$bad" in
            label)
                reason='carries no org.opencontainers.image.base.digest label'
                ;;
            inspect)
                rm "$dir/ours-bazzite-mx.json"
                reason='cannot inspect ghcr.io/matrixdj96/bazzite-mx:stable: UNKNOWN'
                ;;
            base)
                rm "$dir/base-bazzite.env"
                reason='cannot resolve ghcr.io/ublue-os/bazzite:stable: UNKNOWN'
                ;;
        esac

        if output=$(check "$dir" 2>&1); then
            fail_self_test "known-bad input '$bad' produced a verdict"
        fi

        # Known-bad: jq's own line, then a verdict blaming a missing label.
        if grep -q '^jq:' <<< "$output"; then
            fail_self_test "known-bad input '$bad' let jq's line through: ${output//$'\n'/ }"
        fi

        if ! grep -qF "$reason" <<< "$output"; then
            fail_self_test "known-bad input '$bad' refused for another reason: ${output//$'\n'/ }"
        fi
    done

    # Known-bad: skopeo's own lines reached stderr unprefixed.
    skopeo() {
        echo 'time="2026-09-09" level=warning msg="Failed, retrying in 1s ... (1/3)"' >&2
        echo 'time="2026-09-09" level=fatal msg="pinging container registry: no route"' >&2
        return 1
    }
    REFUSED=$((REFUSED + 1))

    if output=$(ours_inspect bazzite-mx "" 2>&1); then
        fail_self_test "a failing inspect of our image answered"
    fi

    if [ "$(grep -c '' <<< "$output")" -ne 1 ] \
        || ! grep -q '^watch-upstream: cannot inspect .*bazzite-mx:stable: .*no route' \
            <<< "$output"; then
        fail_self_test "a failing inspect not folded into one line: ${output//$'\n'/ }"
    fi

    skopeo() {
        echo 'level=fatal msg="reading manifest stable in ghcr.io/x: manifest unknown"' >&2
        return 1
    }

    if ours_inspect bazzite-mx "" > /dev/null 2>&1; then
        status=0
    else
        status=$?
    fi

    if [ "$status" -ne 2 ]; then
        fail_self_test "an absent image exited $status, not 2"
    fi

    unset -f skopeo
}

# self_test_runs_read_failure: a gh that fails is reported on one line of the
# script's own, its reason inside. Known-bad: gh's line reached stderr nude.
self_test_runs_read_failure() {
    local output

    gh() {
        echo 'gh: HTTP 502 Bad Gateway (https://api.github.com/repos/x/actions/runs)' >&2
        echo 'check your internet connection or https://githubstatus.com' >&2
        return 1
    }
    REFUSED=$((REFUSED + 1))

    if output=$(runs_live 2>&1); then
        fail_self_test "a failing gh listed runs"
    fi

    if [ "$(grep -c '' <<< "$output")" -ne 1 ] \
        || ! grep -q '^watch-upstream: cannot read the runs of .*: gh: HTTP 502' <<< "$output"; then
        fail_self_test "a failing gh not folded into one line: ${output//$'\n'/ }"
    fi

    unset -f gh
}

# self_test_run <title> <status> <conclusion> <created at>: a one-run JSON
# array as the release runs.
self_test_run() {
    local title=$1
    local status=$2
    local conclusion=$3
    local created_at=$4

    printf '[{"display_title":"%s","status":"%s","conclusion":%s,"created_at":"%s"}]' \
        "$title" "$status" "$conclusion" "$created_at"
}

# self_test_expect_decision <expected dispatch> <what> <decide argument>...:
# decide prints the expected dispatch line, or the self-test fails with <what>.
self_test_expect_decision() {
    local expected=$1
    local what=$2
    shift 2
    local output

    output=$(decide "$@")

    if ! grep -qx "dispatch=$expected" <<< "$output"; then
        fail_self_test "$what: $output"
    fi
}

# self_test_decisions: nine decisions, each for its own reason.
self_test_decisions() {
    local now old output

    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    old=$(date -u -d '-30 hours' +%Y-%m-%dT%H:%M:%SZ)

    if ! output=$(decide stale upstream:aaaa true '[]' false); then
        fail_self_test "decide failed on a clean slate"
    fi

    if ! grep -qx 'dispatch=true' <<< "$output"; then
        fail_self_test "clean slate did not dispatch: $output"
    fi

    self_test_expect_decision false "verdict current dispatched" \
        current upstream:aaaa true '[]' false
    self_test_expect_decision false "an unset PROMOTE_STABLE dispatched" \
        stale upstream:aaaa '' '[]' false
    self_test_expect_decision false "PROMOTE_STABLE=false dispatched" \
        stale upstream:aaaa false '[]' false
    self_test_expect_decision false "a running release did not coalesce" \
        stale upstream:aaaa true "$(self_test_run 'Release: weekly' in_progress null "$now")" false
    self_test_expect_decision false "a fresh failure with the same reason did not coalesce" \
        stale upstream:aaaa true \
        "$(self_test_run 'Release: upstream:aaaa' completed '"failure"' "$now")" false
    self_test_expect_decision true "a 30 h old run blocked the dispatch" \
        stale upstream:aaaa true \
        "$(self_test_run 'Release: upstream:aaaa' completed '"success"' "$old")" false
    self_test_expect_decision true "a failure with another reason blocked the dispatch" \
        stale upstream:aaaa true \
        "$(self_test_run 'Release: upstream:bbbb' completed '"failure"' "$now")" false

    output=$(decide stale upstream:aaaa true '[]' true)

    if ! grep -qx 'dispatch=false' <<< "$output"; then
        fail_self_test "dry run dispatched: $output"
    fi

    if ! grep -q '^dry run: would dispatch' <<< "$output"; then
        fail_self_test "dry run did not say what it would do: $output"
    fi
}

self_test() {
    local dir

    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    self_test_write_fixtures "$dir"

    self_test_verdicts "$dir"
    self_test_inspect_retry_note "$dir"
    self_test_bad_inputs "$dir"
    self_test_decisions
    self_test_runs_read_failure

    echo "self-test ok: 4 verdicts derived, a retried inspect kept clean," \
        "$REFUSED bad inputs refused, 9 decisions checked"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    check)
        check ""
        ;;
    decide)
        shift
        run_decide "$@"
        ;;
    *)
        exit_with_error "usage: watch-upstream.sh check | decide ... | --self-test"
        ;;
esac
