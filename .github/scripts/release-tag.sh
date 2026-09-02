#!/usr/bin/env bash
# The one owner of the release tag: <fedora>.<build date>, plus .1, .2, ... when
# the day's tag is taken on any package or release, so all three flavours land
# on one tag. A probe that answers nothing fails: it would reuse a live tag. A
# name a deleted immutable release once carried is burnt on GitHub and invisible
# to both probes: never delete a release to reuse its name (docs/gotchas.md).
#
#   release-tag.sh <coords-file>
#       coords-file: the KEY=value output of resolve-base.sh (fedora_version)
#       probes GHCR (skopeo list-tags) and the releases (gh release list)
#   release-tag.sh --from-lists <coords-file> <taken-file> [<date>]
#       taken-file: one tag per line, the union a live run would probe
#       date: YYYYMMDD, default today (UTC)
#   release-tag.sh --self-test
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

next_tag() {
    local fedora=$1 date=$2 taken=$3 tag n=0
    [[ "$fedora" =~ ^[0-9]+$ ]] || {
        err "fedora_version is not a number: '$fedora'"
        return 1
    }
    [[ "$date" =~ ^[0-9]{8}$ ]] || {
        err "date is not YYYYMMDD: '$date'"
        return 1
    }
    [ -s "$taken" ] || {
        err "taken-tags file '$taken' is empty or missing: a probe returned nothing"
        return 1
    }
    tag="${fedora}.${date}"
    while grep -qxF "$tag" "$taken"; do
        n=$((n + 1))
        tag="${fedora}.${date}.${n}"
    done
    echo "$tag"
}

fedora_of() {
    local coords=$1 fedora
    [ -f "$coords" ] || {
        err "coords file '$coords' missing"
        return 1
    }
    fedora=$(sed -n 's/^fedora_version=//p' "$coords")
    [ -n "$fedora" ] || {
        err "no fedora_version in $coords"
        return 1
    }
    echo "$fedora"
}

# A package never published answers "name unknown" and has no tag taken; any
# other registry failure is the probe's. Anonymous, GHCR answers 403 instead,
# so the caller logs in first.
probe_package() {
    local pkg=$1 out=$2 tags
    if tags=$(skopeo list-tags --retry-times 3 "docker://${REGISTRY}/${pkg}" 2> "$out.err"); then
        jq -r '.Tags[]' <<< "$tags" >> "$out" || return 1
    elif grep -q 'name unknown' "$out.err"; then
        echo "note: ${REGISTRY}/${pkg} is not published yet (name unknown): no tag taken there" >&2
    else
        cat "$out.err" >&2
        return 1
    fi
    rm -f "$out.err"
}

# The moving aliases alone keep this union non-empty, so an empty one means a
# probe lied.
probe_taken() {
    local out=$1 pkg
    : > "$out"
    for pkg in $PACKAGES; do
        probe_package "$pkg" "$out" || return 1
    done
    gh release list --repo "$REPO" --limit 500 --json tagName --jq '.[].tagName' >> "$out" || return 1
    [ -s "$out" ] || {
        err "no tag found on ${REGISTRY} nor on the releases of ${REPO}: refusing to pick a tag"
        return 1
    }
}

self_test() {
    local dir coords taken n=0
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    coords=$dir/coords.env
    taken=$dir/taken.txt
    printf 'fedora_version=44\nkernel_version=7.2.1-ogc4.1.fc44.x86_64\n' > "$coords"
    printf '%s\n' stable latest 44.20260902 testing-44.20260902 sha256-abc.sig > "$taken"
    [ "$(next_tag "$(fedora_of "$coords")" 20260903 "$taken")" = 44.20260903 ] \
        || fail "self-test: free day did not give <fedora>.<date>"
    [ "$(next_tag 44 20260902 "$taken")" = 44.20260902.1 ] \
        || fail "self-test: taken day did not give .1"
    echo 44.20260902.1 >> "$taken"
    [ "$(next_tag 44 20260902 "$taken")" = 44.20260902.2 ] \
        || fail "self-test: taken .1 did not give .2"
    : > "$dir/empty.txt"
    for bad in \
        "44|20260903|$dir/empty.txt" \
        "44|20260903|$dir/absent.txt" \
        "|20260903|$taken" \
        "44|2026-09-03|$taken"; do
        n=$((n + 1))
        IFS='|' read -r fedora date file <<< "$bad"
        if next_tag "$fedora" "$date" "$file" > /dev/null 2>&1; then
            fail "self-test: known-bad input $n produced a tag"
        fi
    done
    printf 'kernel_version=7.2.1-ogc4.1.fc44.x86_64\n' > "$dir/nomajor.env"
    if fedora_of "$dir/nomajor.env" > /dev/null 2>&1; then
        fail "self-test: coords without fedora_version accepted"
    fi
    # skopeo and gh are stubbed: an unpublished package must be tolerated and
    # any other registry error must fail the probe.
    skopeo() {
        case "$*" in
            *bazzite-mx-nvidia)
                echo 'FATA[0000] Error listing repository tags: fetching tags list: name unknown' >&2
                return 1
                ;;
            *) echo '{"Tags":["stable","44.20260902"]}' ;;
        esac
    }
    gh() { echo 44.20260901; }
    probe_taken "$dir/probe.txt" || fail "self-test: an unpublished package failed the probe"
    [ "$(sort -u "$dir/probe.txt" | wc -l)" -eq 3 ] || fail "self-test: probe did not gather the published packages' tags: $(tr '\n' ' ' < "$dir/probe.txt")"
    skopeo() {
        echo 'FATA[0000] Error listing repository tags: unauthorized' >&2
        return 1
    }
    n=$((n + 1))
    if probe_taken "$dir/probe2.txt" > /dev/null 2>&1; then
        fail "self-test: a registry error passed the probe"
    fi
    unset -f skopeo gh
    echo "self-test ok: 3 tags derived, 1 unpublished package tolerated, $((n + 1)) bad inputs refused"
}

case "${1:-}" in
    --self-test) self_test ;;
    --from-lists)
        [ $# -ge 3 ] && [ $# -le 4 ] || fail "usage: --from-lists <coords-file> <taken-file> [<date>]"
        tag=$(next_tag "$(fedora_of "$2")" "${4:-$(date -u +%Y%m%d)}" "$3") || exit 1
        emit "release_tag=$tag"
        ;;
    "" | -*) fail "usage: release-tag.sh <coords-file> | --from-lists <coords-file> <taken-file> [<date>] | --self-test" ;;
    *)
        [ $# -eq 1 ] || fail "usage: release-tag.sh <coords-file>"
        taken=$(mktemp)
        trap 'rm -f "$taken"' EXIT
        probe_taken "$taken" || fail "probe of the taken tags failed"
        tag=$(next_tag "$(fedora_of "$1")" "$(date -u +%Y%m%d)" "$taken") || exit 1
        emit "release_tag=$tag"
        ;;
esac
