#!/usr/bin/env bash
# Picks the release tag: <fedora>.<build date>, or the .N one past the day's
# highest suffix taken on any package or release, so all three flavours land on
# one tag.
#
# The taken tags are probed live: skopeo list-tags on every package of
# ghcr.io/matrixdj96 (logged in, docs/gotchas.md § An anonymous probe of a GHCR
# package never published answers 403) and gh release list on the repository. A
# probe that fails stops the run; a probe that answers with no tag at all means
# nothing is taken, which is how a cleaned registry starts again. A name a
# deleted immutable release once carried is burnt on GitHub and invisible to
# both probes, so a release is never deleted to reuse its name; a dispatch can
# force another name instead.
#
# Usage: release-tag.sh <coords-file>
#          <coords-file>  the KEY=value output of resolve-base.sh; only
#                         fedora_version is read
#        release-tag.sh --tag <tag> <coords-file>
#          <tag>          the name to use instead of today's: <fedora>.<date> or
#                         <fedora>.<date>.<n>, with the fedora_version of the
#                         coords file, and not taken by the probes
#        release-tag.sh --self-test
# Output: `release_tag=<tag>` on stdout, and in GITHUB_OUTPUT when a workflow
#   set it; on stderr `note: … is not published yet` for a package GHCR has
#   never seen and `note: no tag on … the day's name is free` when no probe
#   listed a tag.
# Exit status: 0 tag written; 1 on a bad argument, when a probe fails or a
#   forced tag is malformed, of another Fedora or already taken, the reason on
#   stderr as `release-tag: …`.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# --- the tag ------------------------------------------------------------------

# fedora_of <coords file>: the fedora_version of the coords file on stdout.
fedora_of() {
    local coords=$1

    sed -n 's/^fedora_version=//p' "$coords"
}

# next_tag <fedora> <date> <taken file>: <fedora>.<date> on stdout, or the .N
# after the day's highest taken suffix (the bare name counting 0) when one is in
# the taken file; a gap below it is never filled, since it may be a name a
# deleted release burnt. An empty taken file is a registry with no tag: the
# day's name is free.
next_tag() {
    local fedora=$1
    local date=$2
    local taken=$3
    local last

    last=$(sed -nE "s/^${fedora}\.${date}(\.([0-9]+))?\$/\2/p" "$taken" \
        | sed 's/^$/0/' | sort -n | tail -n1)

    if [ -z "$last" ]; then
        echo "${fedora}.${date}"
    else
        echo "${fedora}.${date}.$((last + 1))"
    fi
}

# check_forced_shape <fedora> <tag>: status 0 when the tag has the TAG_SHAPE of
# lib.sh, <fedora>.<yyyymmdd>[.<n>], with the fedora_version of the resolved
# base; status 1 with the reason otherwise. Checked before any probe runs, so a
# typo costs no round trip. The name is the dispatcher's choice, so the shape is
# the only thing checked about the date.
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
# release carries it; status 1 with the reason when it is taken.
check_forced_free() {
    local tag=$1
    local taken=$2

    if grep -qxF "$tag" "$taken"; then
        print_error "forced tag '$tag' is already taken on a package or a release"
        return 1
    fi

    echo "$tag"
}

# --- the probes ---------------------------------------------------------------

# probe_package <package> <taken file>: the tags of the package on GHCR appended
# to the taken file. A package never published answers "name unknown" and has no
# tag taken; any other registry failure is the probe's.
probe_package() {
    local package=$1
    local taken=$2
    local tags error

    if tags=$(skopeo list-tags --retry-times 3 "docker://${REGISTRY}/${package}" \
        2> "$taken.err"); then
        jq -r '.Tags[]' <<< "$tags" >> "$taken"
    elif absent_error "$(< "$taken.err")"; then
        echo "note: ${REGISTRY}/${package} is not published yet (name unknown):" \
            "no tag taken there" >&2
    else
        error=$(< "$taken.err")
        error=${error//$'\n'/ }
        print_error "cannot list the tags of ${REGISTRY}/${package}:" \
            "${error:-no output from skopeo}"
        return 1
    fi
}

# probe_taken <taken file>: the tags of every package and every release of the
# repository, one per line; empty when every probe answered and none listed a
# tag, status 1 when one of them failed.
probe_taken() {
    local taken=$1
    local package error

    : > "$taken"
    for package in $PACKAGES; do
        if ! probe_package "$package" "$taken"; then
            return 1
        fi
    done

    if ! gh release list --repo "$REPO" --limit 500 --json tagName --jq '.[].tagName' \
        >> "$taken" 2> "$taken.err"; then
        error=$(< "$taken.err")
        error=${error//$'\n'/ }
        print_error "cannot list the releases of ${REPO}: ${error:-no output from gh}"
        return 1
    fi

    if [ ! -s "$taken" ]; then
        echo "note: no tag on ${REGISTRY} nor on the releases of ${REPO}: the day's name" \
            "is free" >&2
    fi
}

# --- the command --------------------------------------------------------------

# emit_tag <coords file> <date> <taken file>: next_tag's answer as
# `release_tag=<tag>`.
emit_tag() {
    local coords=$1
    local date=$2
    local taken=$3
    local fedora tag

    fedora=$(fedora_of "$coords")

    tag=$(next_tag "$fedora" "$date" "$taken")
    emit "release_tag=$tag"
}

# emit_forced_tag <coords file> <tag>: the forced tag as `release_tag=<tag>`
# once its shape is accepted and the live probes show it free; exits 1
# otherwise. The taken file is the script-wide `taken`, removed by the EXIT trap
# after the function returns.
emit_forced_tag() {
    local coords=$1
    local forced=$2
    local fedora tag

    fedora=$(fedora_of "$coords")

    if ! check_forced_shape "$fedora" "$forced"; then
        exit 1
    fi

    taken=$(mktemp)
    trap 'rm -f "$taken" "$taken.err"' EXIT

    if ! probe_taken "$taken"; then
        exit_with_error "probe of the taken tags failed"
    fi

    if ! tag=$(check_forced_free "$forced" "$taken"); then
        exit 1
    fi

    emit "release_tag=$tag"
}

# --- self-test ----------------------------------------------------------------

# self_test_next_tag <dir>: a free day gives <fedora>.<date>, a taken day .1, a
# taken .1 gives .2, a .1 without the bare name gives .2 (no gap filled), an
# empty taken file gives the day's name.
self_test_next_tag() {
    local dir=$1
    local coords=$dir/coords.env
    local taken=$dir/taken.txt

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

    echo 44.20260904.1 >> "$taken"

    if [ "$(next_tag 44 20260904 "$taken")" != 44.20260904.2 ]; then
        fail_self_test "a gap below the day's highest suffix was filled"
    fi

    : > "$dir/empty.txt"

    if [ "$(next_tag 44 20260903 "$dir/empty.txt")" != 44.20260903 ]; then
        fail_self_test "empty taken file did not give the day's name"
    fi
}

# self_test_forced_tag <dir>: on its own taken file, a free name of the right
# Fedora passes the shape and the free check, with and without .N; a name of
# another Fedora and a malformed one fail the shape check; a taken name fails
# the free check.
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

    REFUSED=$((REFUSED + 1))

    if check_forced_shape 44 45.20260907 2> /dev/null; then
        fail_self_test "a forced tag of another Fedora passed the shape check"
    fi

    REFUSED=$((REFUSED + 1))

    if check_forced_shape 44 44.20260907-rc1 2> /dev/null; then
        fail_self_test "a malformed forced tag passed the shape check"
    fi

    REFUSED=$((REFUSED + 1))

    if check_forced_free 44.20260906.1 "$taken" > /dev/null 2>&1; then
        fail_self_test "taken forced tag accepted"
    fi
}

# self_test_probes <dir>: probe_taken with skopeo and gh replaced by functions,
# the registry states it reads and the errors it refuses on one line, and a
# malformed forced tag refused before it is emitted.
self_test_probes() {
    local dir=$1
    local output

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

    if ! probe_taken "$dir/probe.txt" 2> /dev/null; then
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

    REFUSED=$((REFUSED + 1))

    if (GITHUB_OUTPUT="" emit_forced_tag "$dir/coords.env" 44.2026104) > /dev/null 2>&1; then
        fail_self_test "a malformed forced tag emitted"
    fi

    # Known-bad: skopeo's and gh's own lines reached stderr unprefixed, the
    # script's line carrying no reason.
    skopeo() {
        echo 'WARN[0000] Failed, retrying in 1s ... (1/3)' >&2
        echo 'FATA[0000] Error listing repository tags: unauthorized' >&2
        return 1
    }
    REFUSED=$((REFUSED + 1))

    if output=$(probe_taken "$dir/probe2.txt" 2>&1); then
        fail_self_test "a registry error passed the probe"
    fi

    if [ "$(grep -c '' <<< "$output")" -ne 1 ] \
        || ! grep -q '^release-tag: cannot list the tags of .* FATA\[0000\] Error listing' \
            <<< "$output"; then
        fail_self_test "a registry error not folded into one line: ${output//$'\n'/ }"
    fi

    skopeo() {
        echo '{"Tags":[]}'
    }
    gh() {
        echo 'gh: HTTP 502 from api.github.com' >&2
        echo 'check your internet connection or https://githubstatus.com' >&2
        return 1
    }
    REFUSED=$((REFUSED + 1))

    if output=$(probe_taken "$dir/probe3.txt" 2>&1); then
        fail_self_test "a gh error passed the probe"
    fi

    if [ "$(grep -c '' <<< "$output")" -ne 1 ] \
        || ! grep -q '^release-tag: cannot list the releases of .*: gh: HTTP 502' \
            <<< "$output"; then
        fail_self_test "a gh error not folded into one line: ${output//$'\n'/ }"
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

    echo "self-test ok: 5 tags derived, 2 forced tags accepted, 1 unpublished package" \
        "and 1 empty registry tolerated, $REFUSED bad inputs refused"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    --tag)
        if [ $# -ne 3 ]; then
            exit_with_error "usage: --tag <tag> <coords-file>"
        fi

        emit_forced_tag "$3" "$2"
        ;;
    "" | -*)
        exit_with_error "usage: release-tag.sh <coords-file>" \
            "| --tag <tag> <coords-file> | --self-test"
        ;;
    *)
        if [ $# -ne 1 ]; then
            exit_with_error "usage: release-tag.sh <coords-file>"
        fi

        taken=$(mktemp)
        trap 'rm -f "$taken" "$taken.err"' EXIT

        if ! probe_taken "$taken"; then
            exit_with_error "probe of the taken tags failed"
        fi

        emit_tag "$1" "$(date -u +%Y%m%d)" "$taken"
        ;;
esac
