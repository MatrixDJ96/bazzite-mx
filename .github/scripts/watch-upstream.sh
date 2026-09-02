#!/usr/bin/env bash
# The upstream watcher: for each flavour, the base's live digest against the
# base.digest label our own :stable carries. The digest and not the version,
# because a retag or a `.N` rebuild upstream moves one and leaves the other.
#
#   watch-upstream.sh check [--from-dir <dir>]
#       one line per flavour, then verdict=current|stale|absent and
#       reason=upstream:<12 hex per base digest, joined by +>. --from-dir
#       reads base-<flavour>.env and ours-<image>.json (or .absent) instead.
#   watch-upstream.sh decide --verdict <v> --reason <r> --promote-var <value>
#                            [--runs-json <file>] [--dry-run]
#       dispatch=true|false. A dispatch needs a stale verdict, PROMOTE_STABLE
#       set to "true", no release run open and none completed with the same
#       reason inside COALESCE_HOURS. --runs-json takes the runs from a file.
#   watch-upstream.sh --self-test
#
# Needs skopeo (logged in to ghcr.io), gh (GH_TOKEN), jq and resolve-base.sh
# beside this script.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

OUR_TAG=stable
RELEASE_WORKFLOW=.github/workflows/release.yml
RUN_NAME_PREFIX="Release: "
COALESCE_HOURS=24
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# GITHUB_OUTPUT is unset for the live call so resolve-base.sh's keys do not
# become outputs of this step.
base_coords() {
    local flavour=$1 dir=$2
    if [ -n "$dir" ]; then
        [ -f "$dir/base-$flavour.env" ] || {
            err "fixture $dir/base-$flavour.env missing"
            return 1
        }
        cat "$dir/base-$flavour.env"
        return 0
    fi
    env -u GITHUB_OUTPUT "$SCRIPT_DIR/resolve-base.sh" "$flavour"
}

# Returns 2 when the image is absent, 1 on any other failure.
ours_inspect() {
    local image=$1 dir=$2 out
    if [ -n "$dir" ]; then
        [ -f "$dir/ours-$image.absent" ] && return 2
        [ -f "$dir/ours-$image.json" ] || {
            err "fixture $dir/ours-$image.json missing"
            return 1
        }
        cat "$dir/ours-$image.json"
        return 0
    fi
    if out=$(skopeo inspect --retry-times 3 --no-tags "docker://${REGISTRY}/${image}:${OUR_TAG}" 2>&1); then
        echo "$out"
        return 0
    fi
    if absent_error "$out"; then
        return 2
    fi
    echo "$out" >&2
    return 1
}

# Fail-closed: an unreadable base or image, or a :stable without the label, is
# UNKNOWN and returns 1, so this run goes red instead of dispatching.
check() {
    local dir=$1 flavour coords image_name base_digest json label rc short
    local stale=0 absent=0 total=0 verdict shorts=""
    for flavour in $FLAVOURS; do
        total=$((total + 1))
        coords=$(base_coords "$flavour" "$dir") || {
            err "cannot resolve ghcr.io/ublue-os/$flavour:stable: UNKNOWN, no dispatch"
            return 1
        }
        image_name=$(sed -n 's/^image_name=//p' <<< "$coords")
        base_digest=$(sed -n 's/^base_digest=//p' <<< "$coords")
        [[ "$image_name" =~ ^bazzite-mx(-nvidia(-open)?)?$ && "$base_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
            err "resolve-base.sh gave no image_name/base_digest for $flavour"
            return 1
        }
        short=${base_digest#sha256:}
        shorts="${shorts:+$shorts+}${short:0:12}"
        rc=0
        json=$(ours_inspect "$image_name" "$dir") || rc=$?
        case "$rc" in
            0) ;;
            2)
                echo "${image_name}:${OUR_TAG} absent: nothing to compare"
                absent=$((absent + 1))
                continue
                ;;
            *)
                err "cannot inspect ${REGISTRY}/${image_name}:${OUR_TAG}: UNKNOWN, no dispatch"
                return 1
                ;;
        esac
        label=$(jq -r '.Labels["org.opencontainers.image.base.digest"] // empty' <<< "$json")
        [[ "$label" =~ ^sha256:[0-9a-f]{64}$ ]] || {
            err "${image_name}:${OUR_TAG} carries no org.opencontainers.image.base.digest label: UNKNOWN, no dispatch (a release restores it)"
            return 1
        }
        if [ "$label" = "$base_digest" ]; then
            echo "${image_name}:${OUR_TAG} current: built on $base_digest"
        else
            echo "${image_name}:${OUR_TAG} stale: built on $label, $flavour:stable is now $base_digest"
            stale=$((stale + 1))
        fi
    done
    if [ "$stale" -gt 0 ]; then
        verdict=stale
    elif [ "$absent" -eq "$total" ]; then
        verdict=absent
    else
        verdict=current
    fi
    emit "verdict=$verdict"
    emit "reason=upstream:$shorts"
}

# Filtered by the workflow's path: the per-workflow endpoint answers 404 while
# the file is not on the default branch (docs/gotchas.md). Each read must
# succeed, because an empty reading is never "no runs".
runs_live() {
    local since recent queued running
    since=$(date -u -d "-${COALESCE_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)
    recent=$(gh api --method GET "repos/$REPO/actions/runs" -f event=workflow_dispatch -f "created=>=$since" -F per_page=100) || return 1
    queued=$(gh api --method GET "repos/$REPO/actions/runs" -f status=queued -F per_page=100) || return 1
    running=$(gh api --method GET "repos/$REPO/actions/runs" -f status=in_progress -F per_page=100) || return 1
    jq -s --arg path "$RELEASE_WORKFLOW" \
        '[.[].workflow_runs[] | select(.path == $path) | {id, display_title, status, conclusion, created_at}] | unique' \
        <<< "$recent$queued$running"
}

decide() {
    local verdict=$1 reason=$2 promote=$3 runs=$4 dry=$5 since open same
    if [ "$verdict" != stale ]; then
        echo "verdict $verdict: no dispatch"
        emit dispatch=false
        return 0
    fi
    if [ "$promote" != true ]; then
        echo "promotion switched off (repository variable PROMOTE_STABLE='${promote}', not 'true'): a release the gate cannot promote is not created; no dispatch"
        emit dispatch=false
        return 0
    fi
    jq -e 'type == "array"' <<< "$runs" > /dev/null 2>&1 || {
        err "the release runs could not be read: no dispatch"
        return 1
    }
    open=$(jq -r '[.[] | select(.status == "queued" or .status == "in_progress" or .status == "waiting" or .status == "pending" or .status == "requested")] | length' <<< "$runs")
    if [ "$open" -gt 0 ]; then
        echo "$open release run(s) queued or in progress: no dispatch"
        emit dispatch=false
        return 0
    fi
    since=$(date -u -d "-${COALESCE_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)
    same=$(jq -r --arg title "${RUN_NAME_PREFIX}${reason}" --arg since "$since" \
        '[.[] | select(.display_title == $title and .status == "completed" and .created_at >= $since)] | length' <<< "$runs")
    if [ "$same" -gt 0 ]; then
        echo "a release with reason '$reason' completed in the last ${COALESCE_HOURS} h: no dispatch"
        emit dispatch=false
        return 0
    fi
    if [ "$dry" = true ]; then
        echo "dry run: would dispatch release.yml with reason '$reason' and promote_stable=true"
        emit dispatch=false
        return 0
    fi
    echo "dispatch release.yml with reason '$reason' and promote_stable=true"
    emit dispatch=true
}

good() {
    printf '{"Digest":"sha256:%064d","Labels":{"org.opencontainers.image.base.digest":"%s"}}\n' 0 "$1"
}

self_test() {
    local dir a b c a2 n=0 out now old
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    a=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76
    b=sha256:c765d566dfbdbdc97808c5b6a00ba0f1b9a5295547490c4b01e1c2ddecf24060
    c=sha256:ca1d0b10df80ac8c6e60b8a3b0b7f0b6d4b2a1c9e8f7d6c5b4a3928170605040
    a2=sha256:1111111111111111111111111111111111111111111111111111111111111111
    mkdir -p "$dir/fx"
    printf 'image_name=bazzite-mx\nbase_digest=%s\n' "$a" > "$dir/fx/base-bazzite.env"
    printf 'image_name=bazzite-mx-nvidia-open\nbase_digest=%s\n' "$b" > "$dir/fx/base-bazzite-nvidia-open.env"
    printf 'image_name=bazzite-mx-nvidia\nbase_digest=%s\n' "$c" > "$dir/fx/base-bazzite-nvidia.env"
    good "$a" > "$dir/fx/ours-bazzite-mx.json"
    good "$b" > "$dir/fx/ours-bazzite-mx-nvidia-open.json"
    good "$c" > "$dir/fx/ours-bazzite-mx-nvidia.json"
    out=$(check "$dir/fx") || fail "self-test: check failed on current images"
    grep -qx 'verdict=current' <<< "$out" || fail "self-test: current images not reported current: $out"
    grep -qx 'reason=upstream:9556db65991d+c765d566dfbd+ca1d0b10df80' <<< "$out" || fail "self-test: reason not derived from the base digests: $out"
    good "$a2" > "$dir/fx/ours-bazzite-mx.json"
    out=$(check "$dir/fx") || fail "self-test: check failed on a stale image"
    grep -qx 'verdict=stale' <<< "$out" || fail "self-test: stale image not reported stale: $out"
    grep -q '^bazzite-mx:stable stale: ' <<< "$out" || fail "self-test: stale line missing: $out"
    rm "$dir/fx/ours-bazzite-mx.json"
    : > "$dir/fx/ours-bazzite-mx.absent"
    out=$(check "$dir/fx") || fail "self-test: check failed with one absent image"
    grep -qx 'verdict=current' <<< "$out" || fail "self-test: absent+current not reported current: $out"
    : > "$dir/fx/ours-bazzite-mx-nvidia-open.absent"
    : > "$dir/fx/ours-bazzite-mx-nvidia.absent"
    rm "$dir/fx/ours-bazzite-mx-nvidia-open.json" "$dir/fx/ours-bazzite-mx-nvidia.json"
    out=$(check "$dir/fx") || fail "self-test: check failed with every image absent"
    grep -qx 'verdict=absent' <<< "$out" || fail "self-test: three absent images not reported absent: $out"
    rm "$dir/fx/ours-bazzite-mx.absent" "$dir/fx/ours-bazzite-mx-nvidia-open.absent" "$dir/fx/ours-bazzite-mx-nvidia.absent"
    good "$b" > "$dir/fx/ours-bazzite-mx-nvidia-open.json"
    good "$c" > "$dir/fx/ours-bazzite-mx-nvidia.json"
    echo '{"Digest":"sha256:x","Labels":{"org.opencontainers.image.version":"44.20260902"}}' > "$dir/fx/ours-bazzite-mx.json"
    for bad in label inspect base; do
        n=$((n + 1))
        case "$bad" in
            inspect) rm "$dir/fx/ours-bazzite-mx.json" ;;
            base) rm "$dir/fx/base-bazzite.env" ;;
        esac
        if check "$dir/fx" > /dev/null 2>&1; then
            fail "self-test: known-bad input '$bad' produced a verdict"
        fi
    done
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    old=$(date -u -d '-30 hours' +%Y-%m-%dT%H:%M:%SZ)
    out=$(decide stale upstream:aaaa true '[]' false) || fail "self-test: decide failed on a clean slate"
    grep -qx 'dispatch=true' <<< "$out" || fail "self-test: clean slate did not dispatch: $out"
    out=$(decide current upstream:aaaa true '[]' false)
    grep -qx 'dispatch=false' <<< "$out" || fail "self-test: verdict current dispatched: $out"
    out=$(decide stale upstream:aaaa '' '[]' false)
    grep -qx 'dispatch=false' <<< "$out" || fail "self-test: an unset PROMOTE_STABLE dispatched: $out"
    out=$(decide stale upstream:aaaa false '[]' false)
    grep -qx 'dispatch=false' <<< "$out" || fail "self-test: PROMOTE_STABLE=false dispatched: $out"
    out=$(decide stale upstream:aaaa true "[{\"display_title\":\"Release: weekly\",\"status\":\"in_progress\",\"conclusion\":null,\"created_at\":\"$now\"}]" false)
    grep -qx 'dispatch=false' <<< "$out" || fail "self-test: a running release did not coalesce: $out"
    out=$(decide stale upstream:aaaa true "[{\"display_title\":\"Release: upstream:aaaa\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"$now\"}]" false)
    grep -qx 'dispatch=false' <<< "$out" || fail "self-test: a fresh failure with the same reason did not coalesce: $out"
    out=$(decide stale upstream:aaaa true "[{\"display_title\":\"Release: upstream:aaaa\",\"status\":\"completed\",\"conclusion\":\"success\",\"created_at\":\"$old\"}]" false)
    grep -qx 'dispatch=true' <<< "$out" || fail "self-test: a 30 h old run blocked the dispatch: $out"
    out=$(decide stale upstream:aaaa true "[{\"display_title\":\"Release: upstream:bbbb\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"$now\"}]" false)
    grep -qx 'dispatch=true' <<< "$out" || fail "self-test: a failure with another reason blocked the dispatch: $out"
    out=$(decide stale upstream:aaaa true '[]' true)
    grep -qx 'dispatch=false' <<< "$out" || fail "self-test: dry run dispatched: $out"
    grep -q '^dry run: would dispatch' <<< "$out" || fail "self-test: dry run did not say what it would do: $out"
    if decide stale upstream:aaaa true 'not json' false > /dev/null 2>&1; then
        fail "self-test: unreadable runs produced a decision"
    fi
    echo "self-test ok: 4 verdicts derived, $n bad inputs refused, 9 decisions checked, unreadable runs refused"
}

case "${1:-}" in
    --self-test) self_test ;;
    check)
        shift
        dir=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --from-dir)
                    dir=$2
                    shift 2
                    ;;
                *) fail "usage: check [--from-dir <dir>]" ;;
            esac
        done
        check "$dir"
        ;;
    decide)
        shift
        verdict="" reason="" promote="" runs_file="" dry=false
        while [ $# -gt 0 ]; do
            case "$1" in
                --verdict)
                    verdict=$2
                    shift 2
                    ;;
                --reason)
                    reason=$2
                    shift 2
                    ;;
                --promote-var)
                    promote=$2
                    shift 2
                    ;;
                --runs-json)
                    runs_file=$2
                    shift 2
                    ;;
                --dry-run)
                    dry=true
                    shift
                    ;;
                *) fail "usage: decide --verdict <v> --reason <r> --promote-var <value> [--runs-json <file>] [--dry-run]" ;;
            esac
        done
        [ -n "$verdict" ] && [ -n "$reason" ] || fail "decide needs --verdict and --reason"
        if [ -n "$runs_file" ]; then
            runs=$(cat "$runs_file")
        elif [ "$verdict" = stale ] && [ "$promote" = true ]; then
            runs=$(runs_live) || fail "cannot list the runs of $REPO: no dispatch"
        else
            runs='[]'
        fi
        decide "$verdict" "$reason" "$promote" "$runs" "$dry"
        ;;
    *) fail "usage: watch-upstream.sh check [--from-dir <dir>] | decide ... | --self-test" ;;
esac
