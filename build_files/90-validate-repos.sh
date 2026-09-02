#!/usr/bin/env bash
# Repository gate: a vendored .repo that is absent, drifted or enabled, a base
# .repo the build modified, and any addition left enabled all fail the build.
# It compares against 00-prep.sh's snapshot, so no list of names to maintain.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

REPOS_DIR=${REPOS_DIR:-/etc/yum.repos.d}
VENDORED_DIR=${VENDORED_DIR:-$CTX/system_files/etc/yum.repos.d}
SNAPSHOT=${SNAPSHOT:-$BUILD_STATE/repos.base.sha256}

# validate: print one line per finding, return 1 if any.
validate() {
    local failed=0 f name base_sum cur_sum
    [ -s "$SNAPSHOT" ] || {
        echo "FAIL: base snapshot $SNAPSHOT missing (00-prep.sh did not run)"
        return 1
    }
    if [ -d "$VENDORED_DIR" ]; then
        for f in "$VENDORED_DIR"/*.repo; do
            [ -e "$f" ] || continue
            name=$(basename "$f")
            if [ ! -f "$REPOS_DIR/$name" ]; then
                echo "FAIL: vendored $name is absent from $REPOS_DIR"
                failed=1
            elif ! cmp -s "$f" "$REPOS_DIR/$name"; then
                echo "FAIL: $name differs from the vendored copy"
                failed=1
            elif grep -q '^enabled=1' "$REPOS_DIR/$name"; then
                echo "FAIL: vendored $name has enabled=1"
                failed=1
            fi
        done
    fi
    # A file the snapshot knows is a base file; anything else is an addition.
    for f in "$REPOS_DIR"/*.repo; do
        [ -e "$f" ] || continue
        name=$(basename "$f")
        base_sum=$(awk -v n="$name" '$2 == n { print $1 }' "$SNAPSHOT")
        if [ -n "$base_sum" ]; then
            cur_sum=$(sha256sum "$f" | awk '{ print $1 }')
            if [ "$cur_sum" != "$base_sum" ]; then
                echo "FAIL: base repo file $name was modified by the build"
                failed=1
            fi
        elif [ -f "$VENDORED_DIR/$name" ]; then
            : # checked above
        elif grep -q '^enabled=1' "$f"; then
            echo "FAIL: added repo file $name has enabled=1"
            failed=1
        else
            echo "added (disabled): $name"
        fi
    done
    return "$failed"
}

self_test() {
    local t vendored repos snap
    t=$(mktemp -d)
    # shellcheck disable=SC2064  # expand now: the local is gone at EXIT
    trap "rm -rf '$t'" EXIT
    vendored=$t/vendored
    repos=$t/repos
    snap=$t/base.sha256
    mkdir -p "$vendored" "$repos"
    printf '[fedora]\nname=Fedora\nenabled=1\n' > "$repos/fedora.repo"
    printf '[terra-mesa]\nenabled=1\n' > "$repos/terra-mesa.repo"
    (cd "$repos" && sha256sum -- *.repo) > "$snap"
    printf '[docker-ce-stable]\nenabled=0\n' > "$vendored/docker-ce.repo"
    cp "$vendored/docker-ce.repo" "$repos/"
    printf '[copr:x:y]\nenabled=0\n' > "$repos/_copr:copr.fedorainfracloud.org:x:y.repo"

    run() { REPOS_DIR=$repos VENDORED_DIR=$vendored SNAPSHOT=$snap validate > "$t/out" 2>&1; }
    expect_fail() {
        if run; then die "self-test: '$1' passed"; fi
        grep -q "FAIL: $2" "$t/out" || die "self-test: '$1' failed for another reason: $(cat "$t/out")"
        echo "self-test: caught $1"
    }

    run || die "self-test: the known-good layout fails: $(cat "$t/out")"
    echo "self-test: known-good layout passes"

    sed -i 's/^enabled=0/enabled=1/' "$repos/docker-ce.repo"
    expect_fail "vendored repo enabled" "docker-ce.repo differs"
    cp "$vendored/docker-ce.repo" "$repos/"
    sed -i 's/^enabled=0/enabled=1/' "$vendored/docker-ce.repo" "$repos/docker-ce.repo"
    expect_fail "vendored repo shipped enabled" "vendored docker-ce.repo has enabled=1"
    sed -i 's/^enabled=1/enabled=0/' "$vendored/docker-ce.repo" "$repos/docker-ce.repo"

    rm "$repos/docker-ce.repo"
    expect_fail "vendored repo absent" "vendored docker-ce.repo is absent"
    cp "$vendored/docker-ce.repo" "$repos/"

    printf '[onepassword]\nenabled=1\n' > "$repos/1password.repo"
    expect_fail "added repo enabled" "added repo file 1password.repo has enabled=1"
    rm "$repos/1password.repo"

    echo 'priority=1' >> "$repos/fedora.repo"
    expect_fail "base repo modified" "base repo file fedora.repo was modified"

    echo "self-test ok: 1 good layout, 5 bad layouts refused"
}

case "${1:-}" in
    --self-test) self_test ;;
    "")
        validate || die "repository validation failed"
        log "validate-repos: no enabled third-party repository, base repositories untouched"
        ;;
    *) die "usage: 90-validate-repos.sh [--self-test]" ;;
esac
