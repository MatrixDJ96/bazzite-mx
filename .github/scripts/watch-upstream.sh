#!/usr/bin/env bash
# Decides whether a release run is dispatched: by the upstream watcher when a
# base moved, by the weekly trigger when the day has no release yet.
#
# check compares, for each flavour, the base's live digest with the base.digest
# label of our own :stable: the digest and not the version, because a retag or
# an upstream `.N` rebuild moves one and leaves the other. Every mode fails
# closed: an unreadable base or image, a :stable without the label, or a run or
# release list that cannot be read exits 1, so the run goes red instead of
# dispatching.
#
# Usage: watch-upstream.sh check
#          one line per flavour, then verdict=current|stale|absent and
#          reason=upstream:<12 hex per base digest, joined by +>
#        watch-upstream.sh decide --verdict <v> --reason <r> --promote-var <p>
#                                 [--dry-run]
#          dispatch=true|false: true on a stale verdict with PROMOTE_STABLE set
#          to "true", no release run open and none started with the same reason
#          inside COALESCE_HOURS
#          --verdict <v>      check's verdict
#          --reason <r>       check's reason, the name of the dispatched run
#          --promote-var <p>  the value of the repository variable
#                             PROMOTE_STABLE, empty when unset
#          --dry-run          say what would be dispatched, dispatch=false
#        watch-upstream.sh weekly
#          dispatch=true|false: false while a release run is open or a release
#          carries today's UTC date
#        watch-upstream.sh --self-test
# Output: the lines above on stdout; verdict, reason and dispatch also in
#   GITHUB_OUTPUT when a workflow set it.
# Exit status: 0 verdict or decision written; 1 when an argument is refused, a
#   base or image cannot be read, :stable lacks the label, the release runs
#   cannot be read, or the release list cannot be read or is no JSON list; the
#   reason on stderr as `watch-upstream: …`.
# Needs jq; decide and weekly also gh (GH_TOKEN); check also skopeo, logged in
#   to ghcr.io, and resolve-base.sh beside this script.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

OUR_TAG=stable
RELEASE_WORKFLOW=.github/workflows/release.yml
RUN_NAME_PREFIX="Release: "
COALESCE_HOURS=24
OURS_ERROR_FILE=$(mktemp)
RUNS_ERROR_FILE=$(mktemp)
RELEASES_ERROR_FILE=$(mktemp)
trap 'rm -f "$OURS_ERROR_FILE" "$RUNS_ERROR_FILE" "$RELEASES_ERROR_FILE"' EXIT
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

# compare_flavour <flavour> <image name> <base digest> <fixture dir>: prints the
# flavour's line and sets flavour_state to current, stale or absent in the
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
# flavour is, absent when every one is, current otherwise) and the reason built
# from the three base digests; status 1 on the first UNKNOWN flavour.
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
# on the default branch (docs/gotchas.md § A workflow that is not on the default
# branch has no runs endpoint).
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

# same_reason_runs <runs json> <reason>: how many runs with that reason in their
# name were started inside COALESCE_HOURS, whatever their status and conclusion.
# The window is on the start, so it spaces the dispatches of one reason however
# long a run then waits for a runner; a run still open is the check before this
# one.
same_reason_runs() {
    local runs=$1
    local reason=$2
    local since

    since=$(date -u -d "-${COALESCE_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)
    jq -r --arg title "${RUN_NAME_PREFIX}${reason}" --arg since "$since" \
        '[.[] | select(.display_title == $title and .created_at >= $since)] | length' \
        <<< "$runs"
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

# day_releases <gh release list json> <yyyymmdd>: how many releases carry that
# day in their tag, any .N suffix included: lib.sh's TAG_SHAPE with the date
# fixed.
day_releases() {
    local releases=$1
    local day=$2

    jq -r --arg shape "${TAG_SHAPE/'[0-9]{8}'/$day}" \
        '[.[] | select(.tagName | test($shape))] | length' <<< "$releases"
}

# decide_weekly <runs json> <releases json> <yyyymmdd>: the decision line and
# dispatch=true|false. Any open release run holds the weekly, the watcher's
# included: it builds what the weekly would.
decide_weekly() {
    local runs=$1
    local releases=$2
    local day=$3
    local open built

    open=$(open_runs "$runs")

    if [ "$open" -gt 0 ]; then
        echo "$open release run(s) queued or in progress: no weekly dispatch"
        emit dispatch=false
        return 0
    fi

    built=$(day_releases "$releases" "$day")

    if [ "$built" -gt 0 ]; then
        echo "$built release(s) of ${day} already published: no weekly dispatch"
        emit dispatch=false
        return 0
    fi

    echo "dispatch release.yml with reason 'weekly' and promote_stable=true"
    emit dispatch=true
}

# --- the commands -------------------------------------------------------------

# run_decide <argument>...: the decide subcommand's options, the runs read live
# (only when a dispatch is still possible), then decide; exits 1 on an unknown
# option, one without its value or a run list it cannot read.
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
                exit_with_error "usage: decide --verdict <v> --reason <r> --promote-var <p>" \
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

# run_weekly: the runs and the releases read live, then decide_weekly on today's
# UTC date; either read failing, or a release list that is not a JSON list,
# exits 1, because an empty reading is never "nothing today".
run_weekly() {
    local runs releases error

    if ! runs=$(runs_live); then
        exit_with_error "cannot list the runs of $REPO: no dispatch"
    fi

    if ! releases=$(gh release list --repo "$REPO" --limit 100 --json tagName \
        2> "$RELEASES_ERROR_FILE"); then
        error=$(< "$RELEASES_ERROR_FILE")
        error=${error//$'\n'/ }
        exit_with_error "gh release list failed: ${error:-no output from gh}: no dispatch"
    fi

    if ! jq -e 'type == "array"' <<< "$releases" > /dev/null 2>&1; then
        exit_with_error "gh release list gave no JSON list: '${releases:0:80}': no dispatch"
    fi

    decide_weekly "$runs" "$releases" "$(date -u +%Y%m%d)"
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

# self_test_expect_check <dir> <pattern> <what> <failure>: check on the fixtures
# succeeds (or the self-test fails with <failure>) and its output holds a line
# matching the pattern (or it fails with <what>).
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

# self_test_verdicts <dir>: current images give current and the reason from the
# three base digests; one stale image gives stale with its line; one absent
# image still gives current; three absent images give absent.
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
# leaves the flavour current, its verdict the one line of output.
self_test_inspect_retry_note() {
    local dir=$1
    local retry_manifest=$dir/retry.json
    local verdict_file=$dir/retry.out
    local flavour_state=""

    self_test_write_ours "$retry_manifest" "$SELF_TEST_DIGEST_A"

    skopeo() {
        echo 'WARN retrying (1/3)' >&2
        cat "$retry_manifest"
    }

    if ! compare_flavour bazzite bazzite-mx "$SELF_TEST_DIGEST_A" "" > "$verdict_file" 2>&1 \
        || [ "$flavour_state" != current ] \
        || [ "$(grep -c '' "$verdict_file")" -ne 1 ]; then
        fail_self_test "a retried inspect gave no clean verdict:" \
            "$(tr '\n' ' ' < "$verdict_file")"
    fi

    unset -f skopeo
}

# self_test_bad_inputs <dir>: the reads of our image and of its base that fail,
# each refused with its own reason or status.
self_test_bad_inputs() {
    local dir=$1
    local bad output status reason

    rm "$dir/ours-bazzite-mx.absent" "$dir/ours-bazzite-mx-nvidia-open.absent" \
        "$dir/ours-bazzite-mx-nvidia.absent"
    self_test_write_ours "$dir/ours-bazzite-mx.json" "$SELF_TEST_DIGEST_A"
    self_test_write_ours "$dir/ours-bazzite-mx-nvidia.json" "$SELF_TEST_DIGEST_C"
    echo '{"Digest":"sha256:x","Labels":{"org.opencontainers.image.version":"44.20260902"}}' \
        > "$dir/ours-bazzite-mx-nvidia-open.json"

    for bad in label inspect base; do
        REFUSED=$((REFUSED + 1))
        case "$bad" in
            label)
                reason='carries no org.opencontainers.image.base.digest label'
                ;;
            inspect)
                rm "$dir/ours-bazzite-mx-nvidia-open.json"
                reason='cannot inspect ghcr.io/matrixdj96/bazzite-mx-nvidia-open:stable: UNKNOWN'
                ;;
            base)
                rm "$dir/base-bazzite-nvidia-open.env"
                reason='cannot resolve ghcr.io/ublue-os/bazzite-nvidia-open:stable: UNKNOWN'
                ;;
        esac

        if output=$(check "$dir" 2>&1); then
            fail_self_test "known-bad input '$bad' produced a verdict"
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
# script's own, its reason inside, and decide gives no answer on runs it could
# not read. Known-bad: gh's line reached stderr nude.
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

    REFUSED=$((REFUSED + 1))

    if output=$(run_decide --verdict stale --reason upstream:aaaa --promote-var true 2>&1); then
        fail_self_test "decide answered on runs it could not read: ${output//$'\n'/ }"
    fi

    unset -f gh
}

# self_test_runs_one_read_failure: the queued and the in_progress reads, failing
# alone, fail runs_live.
self_test_runs_one_read_failure() {
    local filter

    for filter in status=queued status=in_progress; do
        gh() {
            if [[ " $* " == *" $filter "* ]]; then
                echo 'gh: HTTP 502 Bad Gateway' >&2
                return 1
            fi

            echo '{"workflow_runs":[]}'
        }
        REFUSED=$((REFUSED + 1))

        if runs_live > /dev/null 2>&1; then
            fail_self_test "runs_live answered with the $filter read failed"
        fi
    done

    unset -f gh
}

# self_test_runs_live_filter: the runs of every other workflow dropped, the
# watcher's own run among them, so it never counts as an open release.
self_test_runs_live_filter() {
    local runs

    gh() {
        printf '{"workflow_runs":[%s,%s]}' \
            '{"id":1,"path":".github/workflows/watch-upstream.yml","status":"in_progress"}' \
            '{"id":2,"path":".github/workflows/release.yml","status":"completed"}'
    }

    runs=$(runs_live)

    if [ "$(jq -r '[.[].id] | join(" ")' <<< "$runs")" != 2 ]; then
        fail_self_test "runs_live kept another workflow's runs: $runs"
    fi

    unset -f gh
}

# self_test_run <title> <status> <conclusion> <created at>: a one-run JSON array
# as the release runs.
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

    if [ "$(grep '^dispatch=' <<< "$output")" != "dispatch=$expected" ]; then
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

    if [ "$(grep '^dispatch=' <<< "$output")" != dispatch=false ]; then
        fail_self_test "dry run dispatched: $output"
    fi

    if ! grep -q '^dry run: would dispatch' <<< "$output"; then
        fail_self_test "dry run did not say what it would do: $output"
    fi
}

# self_test_weekly: the weekly decided on a day without a release and a day with
# a plain one.
self_test_weekly() {
    local releases='[{"tagName":"44.20261005"},{"tagName":"44.20261006.2"}]'

    if [ "$(decide_weekly '[]' "$releases" 20261007 | grep '^dispatch=')" != dispatch=true ]; then
        fail_self_test "a day without a release did not dispatch the weekly"
    fi

    if [ "$(decide_weekly '[]' "$releases" 20261005 | grep '^dispatch=')" != dispatch=false ]; then
        fail_self_test "a day whose release is published dispatched the weekly"
    fi
}

# self_test_expect_weekly <expected line> <releases> <runs state>: run_weekly on
# a gh whose release list answers <releases> and whose run list is empty, "busy"
# holding a queued release run, "down" in either argument failing that read,
# prints the expected line; a dispatch line exits 0, a refusal 1.
self_test_expect_weekly() {
    local expected=$1
    local releases=$2
    local runs_state=$3
    local output status
    local want=1

    if output=$(SHIM_RELEASES=$releases SHIM_RUNS_STATE=$runs_state run_weekly 2>&1); then
        status=0
    else
        status=$?
    fi

    if [[ "$expected" == dispatch=* ]]; then
        want=0
    else
        REFUSED=$((REFUSED + 1))
    fi

    if [ "$status" -ne "$want" ] || ! grep -qF -- "$expected" <<< "$output"; then
        fail_self_test "weekly on releases '$releases', runs $runs_state exited $status:" \
            "${output//$'\n'/ }"
    fi
}

# self_test_weekly_reads: run_weekly dispatching on readable empty lists, held
# by a release of today or a queued release run, stopped by a run list or a
# release list gh cannot read, or a blank release list.
self_test_weekly_reads() {
    gh() {
        if [ "$1" = release ] && [ "$SHIM_RELEASES" != down ]; then
            printf '%s\n' "$SHIM_RELEASES"
            return 0
        fi

        if [ "$1" != release ] && [ "$SHIM_RUNS_STATE" = busy ]; then
            echo '{"workflow_runs":[{"path":".github/workflows/release.yml","status":"queued"}]}'
            return 0
        fi

        if [ "$1" != release ] && [ "$SHIM_RUNS_STATE" != down ]; then
            echo '{"workflow_runs":[]}'
            return 0
        fi

        echo 'HTTP 502: Bad Gateway' >&2
        return 1
    }

    self_test_expect_weekly dispatch=true '[]' up
    self_test_expect_weekly dispatch=false "[{\"tagName\":\"44.$(date -u +%Y%m%d).1\"}]" up
    self_test_expect_weekly dispatch=false '[]' busy
    self_test_expect_weekly 'cannot list the runs' '[]' down
    self_test_expect_weekly 'gh release list failed: HTTP 502' down up
    self_test_expect_weekly 'gave no JSON list' '' up
    unset -f gh
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
    self_test_runs_one_read_failure
    self_test_runs_live_filter
    self_test_weekly
    self_test_weekly_reads

    echo "self-test ok: 4 verdicts derived, a retried inspect kept clean," \
        "$REFUSED bad inputs refused, 9 decisions and 5 weekly ones checked"
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
    weekly)
        run_weekly
        ;;
    *)
        exit_with_error "usage: watch-upstream.sh check | decide ... | weekly | --self-test"
        ;;
esac
