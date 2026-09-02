#!/usr/bin/env bash
# Checks the commit-message rules of docs/conventions.md § Commits on every
# commit reachable from a revision, merges excepted (a pull request's checkout
# is GitHub's synthetic merge).
#
# The rules: the Conventional Commits subject, its width and no trailing period,
# the blank line before an optional body and the absence of trailers. The lint
# job runs the self-test, then the check over the whole history of the pushed
# ref.
#
# Usage: check-commits.sh [<rev>]
#          <rev>  every commit reachable from it is checked; HEAD when omitted
#        check-commits.sh --self-test
# Output: one `<sha>: <rule>` line per finding on stdout, then a
#   `commits ok: N commit(s)` or `commits: N finding(s) in M commit(s)` line.
# Exit status: 0 clean, 1 findings, a bad argument or an unreadable revision.
set -euo pipefail

MAX_COLUMNS=72
SUBJECT_SHAPE='^(build|chore|ci|docs|feat|fix|refactor|test)(\([a-z0-9-]+\))?: [^ ]'
# The trailer keys git, Gerrit and the agents' clients add; matched on the
# lowercased line, so prose starting with a hyphenated word passes.
TRAILER_SHAPE='^(signed-off-by|co-authored-by|co-developed-by|reviewed-by|acked-by|tested-by'
TRAILER_SHAPE+='|reported-by|suggested-by|helped-by|change-id|claude-session|generated-by): '

# --- one message --------------------------------------------------------------

# check_message <sha> <message file>: findings on stdout, status 1 when there is
# at least one. The rules, in the order they print: subject shape, subject width
# and trailing period, the blank line after the subject, no trailer line.
check_message() {
    local sha=$1
    local file=$2
    local findings=0 subject second line_number=0 line

    subject=$(sed -n 1p "$file")
    second=$(sed -n 2p "$file")

    if [[ ! "$subject" =~ $SUBJECT_SHAPE ]]; then
        echo "$sha: subject is not <type>(<scope>): <what>: '$subject'"
        findings=$((findings + 1))
    fi

    if [ "${#subject}" -gt "$MAX_COLUMNS" ]; then
        echo "$sha: subject is ${#subject} columns, the limit is $MAX_COLUMNS"
        findings=$((findings + 1))
    fi

    if [[ "$subject" =~ \.$ ]]; then
        echo "$sha: subject ends with a period"
        findings=$((findings + 1))
    fi

    if [ -n "$second" ]; then
        echo "$sha: the line after the subject is not blank"
        findings=$((findings + 1))
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))

        if [[ "${line,,}" =~ $TRAILER_SHAPE ]]; then
            echo "$sha: body line $line_number is a trailer: '$line'"
            findings=$((findings + 1))
        fi
    done < "$file"

    [ "$findings" -eq 0 ]
}

# --- one revision -------------------------------------------------------------

# check_revision <rev>: every commit reachable from <rev>, oldest first;
# status 1 on a finding or when git cannot list the revision.
check_revision() {
    local rev=$1
    local file commits=0 commits_with_findings=0 findings=0 sha output count

    file=$(mktemp)
    # shellcheck disable=SC2064  # expand now: the local is gone at RETURN
    trap "rm -f '$file'" RETURN

    while read -r sha; do
        commits=$((commits + 1))
        git log -1 --format=%B "$sha" > "$file"

        if output=$(check_message "${sha:0:7}" "$file"); then
            continue
        fi

        printf '%s\n' "$output"
        commits_with_findings=$((commits_with_findings + 1))
        count=$(wc -l <<< "$output")
        findings=$((findings + count))
    done < <(git rev-list --reverse --no-merges "$rev" 2> /dev/null)

    if [ "$commits" -eq 0 ]; then
        echo "check-commits: no commit reachable from '$rev'" >&2
        return 1
    fi

    if [ "$findings" -gt 0 ]; then
        echo "commits: $findings finding(s) in $commits_with_findings commit(s)"
        return 1
    fi

    echo "commits ok: $commits commit(s)"
}

# --- self-test ----------------------------------------------------------------
#
# In a throwaway repository: 5 commits and a merge pass, one with the subject
# alone and one with a body line over the subject's width; a revision git cannot
# read fails, its empty listing being no clean history; then one commit per
# rule, each failing the check, caught by its own rule and by no other.

self_test_failed() {
    echo "check-commits: self-test: $*" >&2
    exit 1
}

commit_with() {
    git -c commit.gpgsign=false -c user.name=t -c user.email=t@example.invalid \
        commit -q --allow-empty -F - <<< "$1"
}

# One message per rule, in rule order, each breaking exactly its rule.
BAD_NAMES=(
    "subject is not <type>(<scope>): <what>"
    "subject is 77 columns, the limit is 72"
    "subject ends with a period"
    "the line after the subject is not blank"
    "body line 3 is a trailer"
)
BAD_MESSAGES=(
    $'Add the thing\n\nA body that says why.'
    "$(printf 'feat(x): %068d\n\nA body that says why.' 0)"
    $'feat(x): the thing.\n\nA body that says why.'
    $'feat(x): the thing\nA body without the blank line.'
    $'feat(x): the thing\n\nSigned-off-by: someone <someone@example.invalid>'
)

self_test() {
    local dir i output sha

    dir=$(mktemp -d)
    # shellcheck disable=SC2064  # expand now: the local is gone at EXIT
    trap "rm -rf '$dir'" EXIT
    cd "$dir"
    git init -q -b main

    commit_with $'chore: the first commit\n\nWhat it adds, and why it is here.'
    commit_with $'feat(image): the second commit\n\nWhat it adds, and why.\n\nA second paragraph.'

    git checkout -q -b side HEAD~1
    commit_with $'fix(image): the side commit\n\nWhat it fixes, and why.'
    git checkout -q main
    git -c commit.gpgsign=false -c user.name=t -c user.email=t@example.invalid \
        merge -q --no-ff --no-edit side

    commit_with $'docs: a commit with the subject alone'
    commit_with "$(printf 'test: a commit with a long body line\n\n%080d' 0)"

    if ! check_revision HEAD > /dev/null; then
        self_test_failed "the conforming commits have findings:" "$(check_revision HEAD || true)"
    fi

    if output=$(check_revision refs/heads/absent 2>&1) \
        || [ "$output" != "check-commits: no commit reachable from 'refs/heads/absent'" ]; then
        self_test_failed "a revision git cannot read not refused as such: $output"
    fi

    for i in "${!BAD_MESSAGES[@]}"; do
        commit_with "${BAD_MESSAGES[$i]}"
        sha=$(git rev-parse --short=7 HEAD)

        if output=$(check_revision HEAD); then
            self_test_failed "rule $i's commit left the status 0"
        fi

        if ! grep -qF "$sha: ${BAD_NAMES[$i]}" <<< "$output"; then
            self_test_failed "rule $i missed its commit: ${BAD_NAMES[$i]}" "$output"
        fi

        if [ "$(grep -c "^$sha: " <<< "$output")" -ne 1 ]; then
            self_test_failed "rule $i's commit hit more than one rule:" "$output"
        fi
    done

    echo "self-test ok: 5 conforming commits and a merge, 1 unreadable revision refused," \
        "${#BAD_MESSAGES[@]} bad messages each caught once"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    -*)
        echo "check-commits: usage: check-commits.sh [<rev>] | --self-test" >&2
        exit 1
        ;;
    *)
        check_revision "${1:-HEAD}"
        ;;
esac
