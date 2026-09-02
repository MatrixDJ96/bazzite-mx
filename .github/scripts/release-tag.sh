#!/usr/bin/env bash
# The one owner of the release tag: <fedora>.<build date>, plus .1, .2, … when
# the day's tag is taken on any package or release, so all three flavours land
# on one tag. A probe that fails stops the run; a probe that answers with no
# tag at all means nothing is taken, which is how a cleaned registry starts
# again. A name a deleted immutable release once carried is burnt on GitHub
# and invisible to both probes, so a release is never deleted to reuse its
# name (docs/gotchas.md); a dispatch can force another name instead.
#
# Usage: release-tag.sh <coords-file>
#          <coords-file>  the KEY=value output of resolve-base.sh; only
#                         fedora_version is read
#        the taken tags are probed live: skopeo list-tags on every package of
#        ghcr.io/matrixdj96 (logged in: anonymous, GHCR answers 403) and
#        gh release list on the repository
#        release-tag.sh --tag <tag> <coords-file>
#          <tag>          the name to use instead of today's: <fedora>.<date>
#                         or <fedora>.<date>.<n>, with the fedora_version of
#                         the coords file, and not taken by the probes
#        release-tag.sh --from-lists <coords-file> <taken-file> [<date>]
#          <taken-file>   one tag per line, the union a live run would probe;
#                         an empty file means no tag is taken
#          <date>         YYYYMMDD, default today (UTC)
#        release-tag.sh --self-test
# Output: `release_tag=<tag>` on stdout, and in GITHUB_OUTPUT when a workflow
#   set it; on stderr `note: … is not published yet` for a package GHCR has
#   never seen and `note: no tag on … the day's name is free` when no probe
#   listed a tag.
# Exit status: 0 tag written; 1 when the coords file lacks fedora_version, the
#   date is not YYYYMMDD, the taken file is missing, a probe fails or a forced
#   tag is malformed, of another Fedora or already taken, the reason on stderr
#   as `release-tag: …`.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# --- the tag ------------------------------------------------------------------

# fedora_of <coords file>: the fedora_version of the coords file on stdout;
# status 1 with the reason when the file or the value is missing.
fedora_of() {
    local coords=$1
    local fedora

    if [ ! -f "$coords" ]; then
        print_error "coords file '$coords' missing"
        return 1
    fi

    fedora=$(sed -n 's/^fedora_version=//p' "$coords")
    if [ -z "$fedora" ]; then
        print_error "no fedora_version in $coords"
        return 1
    fi

    echo "$fedora"
}

# next_tag <fedora> <date> <taken file>: <fedora>.<date> on stdout, with the
# first free .N suffix when that tag is in the taken file; status 1 with the
# reason for a malformed input or a missing taken file. An empty taken file
# is a registry with no tag: the day's name is free.
next_tag() {
    local fedora=$1
    local date=$2
    local taken=$3
    local tag suffix=0

    if [[ ! "$fedora" =~ ^[0-9]+$ ]]; then
        print_error "fedora_version is not a number: '$fedora'"
        return 1
    fi
    if [[ ! "$date" =~ ^[0-9]{8}$ ]]; then
        print_error "date is not YYYYMMDD: '$date'"
        return 1
    fi
    if [ ! -f "$taken" ]; then
        print_error "taken-tags file '$taken' is missing"
        return 1
    fi

    tag="${fedora}.${date}"
    while grep -qxF "$tag" "$taken"; do
        suffix=$((suffix + 1))
        tag="${fedora}.${date}.${suffix}"
    done

    echo "$tag"
}

# check_forced_shape <fedora> <tag>: status 0 when the tag has the TAG_SHAPE
# of lib.sh, <fedora>.<yyyymmdd>[.<n>], with the fedora_version of the
# resolved base; status 1 with the reason otherwise. Checked before any probe
# runs, so a typo costs no round trip. The name is the dispatcher's choice, so
# the shape is the only thing checked about the date.
check_forced_shape() {
    local fedora=$1
    local tag=$2

    if [[ ! "$tag" =~ $TAG_SHAPE ]]; then
        print_error "forced tag is not <fedora>.<yyyymmdd>[.<n>]: '$tag'"
        return 1
    fi
    if [ "${tag%%.*}" != "$fedora" ]; then
        print_error "forced tag '$tag' is not on Fedora $fedora, the resolved base"
        return 1
    fi
}

# check_forced_free <tag> <taken file>: the tag on stdout when no package or
# release carries it; status 1 with the reason when it is taken or the taken
# file is missing.
check_forced_free() {
    local tag=$1
    local taken=$2

    if [ ! -f "$taken" ]; then
        print_error "taken-tags file '$taken' is missing"
        return 1
    fi
    if grep -qxF "$tag" "$taken"; then
        print_error "forced tag '$tag' is already taken on a package or a release"
        return 1
    fi

    echo "$tag"
}

# --- the probes ---------------------------------------------------------------

# probe_package <package> <taken file>: the tags of the package on GHCR
# appended to the taken file. A package never published answers "name
# unknown" and has no tag taken; any other registry failure is the probe's.
probe_package() {
    local package=$1
    local taken=$2
    local tags

    if tags=$(skopeo list-tags --retry-times 3 "docker://${REGISTRY}/${package}" \
        2> "$taken.err"); then
        if ! jq -r '.Tags[]' <<< "$tags" >> "$taken"; then
            return 1
        fi
    elif grep -q 'name unknown' "$taken.err"; then
        echo "note: ${REGISTRY}/${package} is not published yet (name unknown):" \
            "no tag taken there" >&2
    else
        cat "$taken.err" >&2
        return 1
    fi

    rm -f "$taken.err"
}

# probe_taken <taken file>: the tags of every package and every release of
# the repository, one per line; empty when every probe answered and none
# listed a tag, status 1 when one of them failed.
probe_taken() {
    local taken=$1
    local package

    : > "$taken"
    for package in $PACKAGES; do
        if ! probe_package "$package" "$taken"; then
            return 1
        fi
    done

    if ! gh release list --repo "$REPO" --limit 500 --json tagName --jq '.[].tagName' \
        >> "$taken"; then
        return 1
    fi

    if [ ! -s "$taken" ]; then
        echo "note: no tag on ${REGISTRY} nor on the releases of ${REPO}: the day's name" \
            "is free" >&2
    fi
}

# --- the command --------------------------------------------------------------

# emit_tag <coords file> <date> <taken file>: the next free tag as
# `release_tag=<tag>`; exits 1 when an input is refused.
emit_tag() {
    local coords=$1
    local date=$2
    local taken=$3
    local fedora tag

    if ! fedora=$(fedora_of "$coords"); then
        exit 1
    fi
    if ! tag=$(next_tag "$fedora" "$date" "$taken"); then
        exit 1
    fi

    emit "release_tag=$tag"
}

# emit_forced_tag <coords file> <tag>: the forced tag as `release_tag=<tag>`
# once its shape is accepted and the live probes show it free; exits 1
# otherwise. The taken file is the script-wide `taken`, removed by the EXIT
# trap after the function returns.
emit_forced_tag() {
    local coords=$1
    local forced=$2
    local fedora tag

    if ! fedora=$(fedora_of "$coords"); then
        exit 1
    fi
    if ! check_forced_shape "$fedora" "$forced"; then
        exit 1
    fi

    taken=$(mktemp)
    trap 'rm -f "$taken"' EXIT
    if ! probe_taken "$taken"; then
        exit_with_error "probe of the taken tags failed"
    fi
    if ! tag=$(check_forced_free "$forced" "$taken"); then
        exit 1
    fi

    emit "release_tag=$tag"
}

# --- self-test ----------------------------------------------------------------

# self_test_next_tag <dir>: a free day gives <fedora>.<date>, a taken day .1,
# a taken .1 gives .2, an empty taken file gives the day's name; an absent
# taken file, an empty fedora and a dashed date produce no tag; a coords
# file without fedora_version is refused.
self_test_next_tag() {
    local dir=$1
    local coords=$dir/coords.env
    local taken=$dir/taken.txt
    local bad fedora date file

    printf 'fedora_version=44\nkernel_version=7.2.1-ogc4.1.fc44.x86_64\n' > "$coords"
    printf '%s\n' stable latest 44.20260902 testing-44.20260902 sha256-abc.sig > "$taken"

    if [ "$(next_tag "$(fedora_of "$coords")" 20260903 "$taken")" != 44.20260903 ]; then
        fail_self_test "free day did not give <fedora>.<date>"
    fi
    if [ "$(next_tag 44 20260902 "$taken")" != 44.20260902.1 ]; then
        fail_self_test "taken day did not give .1"
    fi
    echo 44.20260902.1 >> "$taken"
    if [ "$(next_tag 44 20260902 "$taken")" != 44.20260902.2 ]; then
        fail_self_test "taken .1 did not give .2"
    fi

    : > "$dir/empty.txt"
    if [ "$(next_tag 44 20260903 "$dir/empty.txt")" != 44.20260903 ]; then
        fail_self_test "empty taken file did not give the day's name"
    fi

    for bad in \
        "44|20260903|$dir/absent.txt" \
        "|20260903|$taken" \
        "44|2026-09-03|$taken"; do
        REFUSED=$((REFUSED + 1))
        IFS='|' read -r fedora date file <<< "$bad"
        if next_tag "$fedora" "$date" "$file" > /dev/null 2>&1; then
            fail_self_test "known-bad input $REFUSED produced a tag"
        fi
    done

    printf 'kernel_version=7.2.1-ogc4.1.fc44.x86_64\n' > "$dir/nomajor.env"
    REFUSED=$((REFUSED + 1))
    if fedora_of "$dir/nomajor.env" > /dev/null 2>&1; then
        fail_self_test "coords without fedora_version accepted"
    fi
}

# self_test_forced_tag <dir>: on its own taken file, a free name of the right
# Fedora passes the shape and the free check, with and without .N; a name of
# another Fedora and two malformed ones fail the shape check; a taken name
# and an absent taken file fail the free check.
self_test_forced_tag() {
    local dir=$1
    local taken=$dir/forced-taken.txt
    local tag

    printf '%s\n' stable staging 44.20260906.1 > "$taken"

    for tag in 44.20260907 44.20260907.3; do
        if ! check_forced_shape 44 "$tag"; then
            fail_self_test "free forced tag $tag failed the shape check"
        fi
        if [ "$(check_forced_free "$tag" "$taken")" != "$tag" ]; then
            fail_self_test "free forced tag $tag refused"
        fi
    done

    for tag in 45.20260907 44.2026-09-07 44.20260907-rc1; do
        REFUSED=$((REFUSED + 1))
        if check_forced_shape 44 "$tag" 2> /dev/null; then
            fail_self_test "known-bad forced tag $tag passed the shape check"
        fi
    done

    REFUSED=$((REFUSED + 1))
    if check_forced_free 44.20260906.1 "$taken" > /dev/null 2>&1; then
        fail_self_test "taken forced tag accepted"
    fi
    REFUSED=$((REFUSED + 1))
    if check_forced_free 44.20260907 "$dir/absent.txt" > /dev/null 2>&1; then
        fail_self_test "forced tag accepted without a taken file"
    fi
}

# self_test_probes <dir>: with skopeo and gh replaced by functions, an
# unpublished package is tolerated and the other packages' tags gathered, a
# registry with no tag at all answers an empty file, then a registry error
# fails the probe.
self_test_probes() {
    local dir=$1

    skopeo() {
        case "$*" in
            *bazzite-mx-nvidia)
                echo 'FATA[0000] Error listing repository tags: fetching tags list:' \
                    'name unknown' >&2
                return 1
                ;;
            *)
                echo '{"Tags":["stable","44.20260902"]}'
                ;;
        esac
    }
    gh() {
        echo 44.20260901
    }

    if ! probe_taken "$dir/probe.txt"; then
        fail_self_test "an unpublished package failed the probe"
    fi
    if [ "$(sort -u "$dir/probe.txt" | wc -l)" -ne 3 ]; then
        fail_self_test "probe did not gather the published packages' tags:" \
            "$(tr '\n' ' ' < "$dir/probe.txt")"
    fi

    skopeo() {
        echo '{"Tags":[]}'
    }
    gh() {
        :
    }
    if ! probe_taken "$dir/probe-empty.txt" 2> /dev/null; then
        fail_self_test "a registry with no tag failed the probe"
    fi
    if [ -s "$dir/probe-empty.txt" ]; then
        fail_self_test "a registry with no tag gathered tags"
    fi

    skopeo() {
        echo 'FATA[0000] Error listing repository tags: unauthorized' >&2
        return 1
    }
    REFUSED=$((REFUSED + 1))
    if probe_taken "$dir/probe2.txt" > /dev/null 2>&1; then
        fail_self_test "a registry error passed the probe"
    fi

    unset -f skopeo gh
}

self_test() {
    local dir

    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN

    self_test_next_tag "$dir"
    self_test_forced_tag "$dir"
    self_test_probes "$dir"

    echo "self-test ok: 4 tags derived, 2 forced tags accepted, 1 unpublished package" \
        "and 1 empty registry tolerated, $REFUSED bad inputs refused"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    --from-lists)
        if [ $# -lt 3 ] || [ $# -gt 4 ]; then
            exit_with_error "usage: --from-lists <coords-file> <taken-file> [<date>]"
        fi
        emit_tag "$2" "${4:-$(date -u +%Y%m%d)}" "$3"
        ;;
    --tag)
        if [ $# -ne 3 ]; then
            exit_with_error "usage: --tag <tag> <coords-file>"
        fi
        emit_forced_tag "$3" "$2"
        ;;
    "" | -*)
        exit_with_error "usage: release-tag.sh <coords-file> | --tag <tag> <coords-file>" \
            "| --from-lists <coords-file> <taken-file> [<date>] | --self-test"
        ;;
    *)
        if [ $# -ne 1 ]; then
            exit_with_error "usage: release-tag.sh <coords-file>"
        fi
        taken=$(mktemp)
        trap 'rm -f "$taken"' EXIT
        if ! probe_taken "$taken"; then
            exit_with_error "probe of the taken tags failed"
        fi
        emit_tag "$1" "$(date -u +%Y%m%d)" "$taken"
        ;;
esac
