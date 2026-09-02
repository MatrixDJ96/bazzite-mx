#!/usr/bin/env bash
# Repository gate: a vendored .repo that is absent, drifted or enabled, a base
# .repo the build modified, any addition left enabled, and an enabled set dnf5
# reports that differs from the base's all fail the build. It compares against
# 00-prep.sh's snapshots, so no list of names to maintain.
#
# Usage: 90-validate-repos.sh              run by build.sh after the last install
#        90-validate-repos.sh --self-test  the gate on a fixture tree, one good
#                                          layout and six bad ones
# Reads: $BUILD_STATE/repos.base.sha256 and repos.base.enabled. The self-test
#   points REPOS_DIR, VENDORED_DIR, SNAPSHOT, ENABLED_BASE and ROOT at its
#   fixture.
# Output: one `FAIL: …` line per finding, `added (disabled): <file>` per
#   addition that passes.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

REPOS_DIR=${REPOS_DIR:-/etc/yum.repos.d}
VENDORED_DIR=${VENDORED_DIR:-$CTX/system_files/etc/yum.repos.d}
SNAPSHOT=${SNAPSHOT:-$BUILD_STATE/repos.base.sha256}
ENABLED_BASE=${ENABLED_BASE:-$BUILD_STATE/repos.base.enabled}
ROOT=${ROOT:-/}

# --- the checks ---------------------------------------------------------------
#
# Each check prints one line per finding and returns 1 when it found any.

# Every vendored file is in place, byte-identical, and disabled.
check_vendored_files() {
    local file name failed=0

    if [ ! -d "$VENDORED_DIR" ]; then
        return 0
    fi

    for file in "$VENDORED_DIR"/*.repo; do
        if [ ! -e "$file" ]; then
            continue
        fi

        name=$(basename "$file")

        if [ ! -f "$REPOS_DIR/$name" ]; then
            echo "FAIL: vendored $name is absent from $REPOS_DIR"
            failed=1
        elif ! cmp -s "$file" "$REPOS_DIR/$name"; then
            echo "FAIL: $name differs from the vendored copy"
            failed=1
        elif grep -q '^enabled=1' "$REPOS_DIR/$name"; then
            echo "FAIL: vendored $name has enabled=1"
            failed=1
        fi
    done

    return "$failed"
}

# A file the snapshot knows is a base file and must be untouched; a vendored
# one was checked above; anything else is an addition and must be disabled.
check_repo_files() {
    local file name base_sum current_sum failed=0

    for file in "$REPOS_DIR"/*.repo; do
        if [ ! -e "$file" ]; then
            continue
        fi

        name=$(basename "$file")
        base_sum=$(awk -v n="$name" '$2 == n { print $1 }' "$SNAPSHOT")

        if [ -n "$base_sum" ]; then
            current_sum=$(sha256sum "$file" | awk '{ print $1 }')

            if [ "$current_sum" != "$base_sum" ]; then
                echo "FAIL: base repo file $name was modified by the build"
                failed=1
            fi
        elif [ -f "$VENDORED_DIR/$name" ]; then
            continue
        elif grep -q '^enabled=1' "$file"; then
            echo "FAIL: added repo file $name has enabled=1"
            failed=1
        else
            echo "added (disabled): $name"
        fi
    done

    return "$failed"
}

# dnf5's own answer, the override files under /etc/dnf/repos.override.d/
# included: the enabled set must be the one the base had.
check_enabled_set() {
    local enabled_now name failed=0

    if ! enabled_now=$(enabled_repos "$ROOT"); then
        echo "FAIL: dnf5 repolist failed under $ROOT"
        return 1
    fi

    while IFS= read -r name; do
        echo "FAIL: repository $name is enabled (dnf5 repolist), not in the base's set"
        failed=1
    done < <(LC_ALL=C comm -13 "$ENABLED_BASE" <(echo "$enabled_now"))

    while IFS= read -r name; do
        echo "FAIL: base repository $name is no longer enabled (dnf5 repolist)"
        failed=1
    done < <(LC_ALL=C comm -23 "$ENABLED_BASE" <(echo "$enabled_now"))

    return "$failed"
}

# Every check runs, so one run lists every finding; status 1 on any.
validate() {
    local failed=0

    if [ ! -s "$SNAPSHOT" ] || [ ! -s "$ENABLED_BASE" ]; then
        echo "FAIL: base snapshot $SNAPSHOT or $ENABLED_BASE missing (00-prep.sh did not run)"
        return 1
    fi

    if ! check_vendored_files; then
        failed=1
    fi

    if ! check_repo_files; then
        failed=1
    fi

    if ! check_enabled_set; then
        failed=1
    fi

    return "$failed"
}

# --- the self-test ------------------------------------------------------------

# A fixture under <dir>: two base repositories, a vendored one in place, a
# COPR file dnf5 left disabled. Each carries a baseurl so dnf5 has
# repositories to list; nothing is fetched.
self_test_write_fixture() {
    local dir=$1
    local repos=$dir/root/etc/yum.repos.d
    local vendored=$dir/vendored

    mkdir -p "$vendored" "$repos" "$dir/root/etc/dnf/repos.override.d"

    printf '[fedora]\nname=Fedora\nbaseurl=file:///nowhere\nenabled=1\n' > "$repos/fedora.repo"
    printf '[terra-mesa]\nname=Terra Mesa\nbaseurl=file:///nowhere\nenabled=1\n' \
        > "$repos/terra-mesa.repo"
    (cd "$repos" && sha256sum -- *.repo) > "$dir/base.sha256"
    printf 'fedora\nterra-mesa\n' > "$dir/base.enabled"

    printf '[docker-ce-stable]\nname=Docker\nbaseurl=file:///nowhere\nenabled=0\n' \
        > "$vendored/docker-ce.repo"
    cp "$vendored/docker-ce.repo" "$repos/"
    printf '[copr:x:y]\nname=x\nbaseurl=file:///nowhere\nenabled=0\n' \
        > "$repos/_copr:copr.fedorainfracloud.org:x:y.repo"
}

# Runs the gate on the fixture under <dir>, output to <dir>/out.
self_test_run() {
    local dir=$1

    ROOT=$dir/root \
        REPOS_DIR=$dir/root/etc/yum.repos.d \
        VENDORED_DIR=$dir/vendored \
        SNAPSHOT=$dir/base.sha256 \
        ENABLED_BASE=$dir/base.enabled \
        validate > "$dir/out" 2>&1
}

# The layout <what> must be refused with a finding that starts with <message>.
self_test_expect_fail() {
    local dir=$1
    local what=$2
    local message=$3

    if self_test_run "$dir"; then
        fail_build "self-test: '$what' passed"
    fi

    if ! grep -q "FAIL: $message" "$dir/out"; then
        fail_build "self-test: '$what' failed for another reason: $(cat "$dir/out")"
    fi

    echo "self-test: caught $what"
}

self_test_bad_layouts() {
    local dir=$1
    local repos=$dir/root/etc/yum.repos.d
    local vendored=$dir/vendored
    local override=$dir/root/etc/dnf/repos.override.d

    sed -i 's/^enabled=0/enabled=1/' "$repos/docker-ce.repo"
    self_test_expect_fail "$dir" "vendored repo enabled" "docker-ce.repo differs"
    cp "$vendored/docker-ce.repo" "$repos/"

    sed -i 's/^enabled=0/enabled=1/' "$vendored/docker-ce.repo" "$repos/docker-ce.repo"
    self_test_expect_fail "$dir" "vendored repo shipped enabled" \
        "vendored docker-ce.repo has enabled=1"
    sed -i 's/^enabled=1/enabled=0/' "$vendored/docker-ce.repo" "$repos/docker-ce.repo"

    rm "$repos/docker-ce.repo"
    self_test_expect_fail "$dir" "vendored repo absent" "vendored docker-ce.repo is absent"
    cp "$vendored/docker-ce.repo" "$repos/"

    printf '[onepassword]\nname=1Password\nbaseurl=file:///nowhere\nenabled=1\n' \
        > "$repos/1password.repo"
    self_test_expect_fail "$dir" "added repo enabled" "added repo file 1password.repo has enabled=1"
    rm "$repos/1password.repo"

    # Every .repo file disabled or the base's; the override file dnf5 reads
    # after them enables one (what `dnf5 config-manager setopt` writes).
    printf '[docker-ce-stable]\nenabled=1\n' > "$override/99-config_manager.repo"
    self_test_expect_fail "$dir" "repository enabled through repos.override.d" \
        "repository docker-ce-stable is enabled"
    rm "$override/99-config_manager.repo"

    echo 'priority=1' >> "$repos/fedora.repo"
    self_test_expect_fail "$dir" "base repo modified" "base repo file fedora.repo was modified"
}

self_test() {
    local dir

    dir=$(mktemp -d)
    # shellcheck disable=SC2064  # expand now: the local is gone at EXIT
    trap "rm -rf '$dir'" EXIT

    self_test_write_fixture "$dir"

    if ! self_test_run "$dir"; then
        fail_build "self-test: the known-good layout fails: $(cat "$dir/out")"
    fi

    echo "self-test: known-good layout passes"
    self_test_bad_layouts "$dir"

    echo "self-test ok: 1 good layout, 6 bad layouts refused"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    "")
        if ! validate; then
            fail_build "repository validation failed"
        fi

        log "validate-repos: no enabled third-party repository, base repositories untouched," \
            "enabled: $(enabled_repos | paste -sd ' ')"
        ;;
    *)
        fail_build "usage: 90-validate-repos.sh [--self-test]"
        ;;
esac
