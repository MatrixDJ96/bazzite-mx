#!/usr/bin/env bash
# The commit-message rules of docs/conventions.md § Commits as a check over
# every commit reachable from a revision: the Conventional Commits subject,
# its width, the blank line, a body that says what and why, the body width
# and the absence of trailers. The lint job runs its self-test, then the
# check over the whole history of the pushed ref.
#
# Usage: check-commits.sh [<rev>]    every commit reachable from <rev>, HEAD
#                                    when omitted
#        check-commits.sh --self-test
# Output: one `<sha>: <rule>` line per finding on stdout, then a
# `commits ok: N commit(s)` or `commits: N finding(s) in M commit(s)` line.
# Exit status: 0 clean, 1 findings or a revision git cannot read.
set -euo pipefail

MAX_COLUMNS=72
SUBJECT_SHAPE='^(build|chore|ci|docs|feat|fix|refactor|test)(\([a-z0-9-]+\))?: [^ ]'
# The trailer keys git, Gerrit and the agents' clients add; matched on the
# lowercased line, so prose starting with a hyphenated word passes.
TRAILER_SHAPE='^(signed-off-by|co-authored-by|co-developed-by|reviewed-by|acked-by|tested-by'
TRAILER_SHAPE+='|reported-by|suggested-by|helped-by|change-id|claude-session|generated-by): '

# --- one message --------------------------------------------------------------

# check_message <sha> <message file>: findings on stdout, status 1 when there
# is at least one. The rules, in the order they print: subject shape, subject
# width and trailing period, the blank line after the subject, a body with at
# least one non-empty line, every line within the width, no trailer line.
check_message() {
    local sha=$1
    local file=$2
    local findings=0 subject second line_number=0 line body_lines=0

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
        if [ "$line_number" -eq 1 ]; then
            continue
        fi
        if [ -n "$line" ]; then
            body_lines=$((body_lines + 1))
        fi
        if [ "${#line}" -gt "$MAX_COLUMNS" ]; then
            echo "$sha: body line $line_number is ${#line} columns, the limit is $MAX_COLUMNS"
            findings=$((findings + 1))
        fi
        if [[ "${line,,}" =~ $TRAILER_SHAPE ]]; then
            echo "$sha: body line $line_number is a trailer: '$line'"
            findings=$((findings + 1))
        fi
    done < "$file"

    if [ "$body_lines" -eq 0 ]; then
        echo "$sha: no body: say what the commit adds and why"
        findings=$((findings + 1))
    fi

    [ "$findings" -eq 0 ]
}

# --- one revision -------------------------------------------------------------

# check_revision <rev>: every commit reachable from <rev>, oldest first;
# status 1 on a finding or when git cannot list the revision.
check_revision() {
    local rev=$1
    local file commits=0 commits_with_findings=0 findings=0 sha output

    file=$(mktemp)
    # shellcheck disable=SC2064  # expand now: the local is gone at EXIT
    trap "rm -f '$file'" RETURN

    while read -r sha; do
        commits=$((commits + 1))
        git log -1 --format=%B "$sha" > "$file"
        if output=$(check_message "${sha:0:7}" "$file"); then
            continue
        fi
        printf '%s\n' "$output"
        commits_with_findings=$((commits_with_findings + 1))
        findings=$((findings + $(wc -l <<< "$output")))
    done < <(git rev-list --reverse "$rev")

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
# In a throwaway repository: two conforming commits pass; then one commit per
# rule, each caught by its own rule and by no other.

self_test_failed() {
    echo "self-test: $*"
    exit 1
}

# commit_with <message>: an empty commit carrying the message, unsigned.
commit_with() {
    git -c commit.gpgsign=false -c user.name=t -c user.email=t@example.invalid \
        commit -q --allow-empty -F - <<< "$1"
}

# One message per rule, in rule order, each breaking exactly its rule. The
# messages hold banned shapes as data.
BAD_NAMES=(
    "subject is not <type>(<scope>): <what>"
    "subject is 77 columns, the limit is 72"
    "subject ends with a period"
    "the line after the subject is not blank"
    "no body: say what the commit adds and why"
    "body line 3 is 80 columns, the limit is 72"
    "body line 3 is a trailer"
)
BAD_MESSAGES=(
    $'Add the thing\n\nA body that says why.'
    "$(printf 'feat(x): %068d\n\nA body that says why.' 0)"
    $'feat(x): the thing.\n\nA body that says why.'
    $'feat(x): the thing\nA body without the blank line.'
    $'feat(x): the thing'
    "$(printf 'feat(x): the thing\n\n%080d' 0)"
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
    if ! check_revision HEAD > /dev/null; then
        self_test_failed "the conforming commits have findings:" "$(check_revision HEAD || true)"
    fi

    for i in "${!BAD_MESSAGES[@]}"; do
        commit_with "${BAD_MESSAGES[$i]}"
        sha=$(git rev-parse --short=7 HEAD)
        output=$(check_revision HEAD || true)
        if ! grep -qF "$sha: ${BAD_NAMES[$i]}" <<< "$output"; then
            self_test_failed "rule $i missed its commit: ${BAD_NAMES[$i]}" "$output"
        fi
        if [ "$(grep -c "^$sha: " <<< "$output")" -ne 1 ]; then
            self_test_failed "rule $i's commit hit more than one rule:" "$output"
        fi
    done

    echo "self-test ok: 2 conforming commits, ${#BAD_MESSAGES[@]} bad messages each caught once"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    -*)
        echo "usage: check-commits.sh [<rev>] | --self-test" >&2
        exit 1
        ;;
    *)
        check_revision "${1:-HEAD}"
        ;;
esac
