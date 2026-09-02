#!/usr/bin/env bash
# The pin refresh of the repository, run by hand and never by a bot: one table
# row per pinned action, installed binary, runner label, workflow state and
# cited issue, and on request the rewrite of the stale actions and binaries.
# Every lookup goes through `gh api`; FIXTURE_DIR replaces them with files.
#
# Usage: refresh-pins.sh [--check]     the table, one row per item
#        refresh-pins.sh --apply       rewrite the STALE actions and binaries in
#                                      the workflows; runners, workflow states
#                                      and issues are reported only
#        refresh-pins.sh --self-test   the verdicts on fixtures, offline
# Environment: WORKFLOWS, the directory of the workflows (default
#   .github/workflows); FIXTURE_DIR, a directory of `<api path>.json` files
#   that stand in for `gh api`, the path's `/?=&` turned into `_`; REPO, the
#   repository whose workflow states are read (lib.sh's default).
# Output: --check prints the table (`class | item | pinned | latest | state |
#   detail`, states OK, STALE, UNKNOWN, FOREIGN, DISABLED, CLOSED); --apply
#   prints one `applied: …` line per rewritten pin and `apply done: N pins
#   rewritten …`.
# Exit status: 0 always for --check and --apply, a stale pin being a row and
#   not a failure; 1 for an unknown argument or a failed self-test, the reason
#   on stderr as `refresh-pins: …`.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

WORKFLOWS=${WORKFLOWS:-.github/workflows}
FIXTURE_DIR=${FIXTURE_DIR:-}

# The binaries the workflows install: <workflow key>=<owner/repo of the binary>.
BINARIES="cosign-release=sigstore/cosign syft-version=anchore/syft ORAS_VERSION=oras-project/oras"

# A pinned action: `uses: owner/repo[/path]@<full sha>`, then the version
# comment when there is one.
PINNED_USES='uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[A-Za-z0-9_./-]+)?@[0-9a-f]{40}( *# *[^ ]+)?'

# A runner label: a literal, or the quoted fallback of `${{ vars.X || 'label' }}`.
RUNS_ON_LITERAL='[a-z0-9.-]+'
RUNS_ON_FALLBACK="\\\$\\{\\{ *vars\\.[A-Za-z_]+ *\\|\\| *'[a-z0-9.-]+' *\\}\\}"
RUNS_ON="^ *runs-on: *(${RUNS_ON_LITERAL}|${RUNS_ON_FALLBACK})"

# --- lookups ------------------------------------------------------------------

# github_api <path>: the JSON of a GitHub API GET on stdout, or nothing when
# the call fails; with FIXTURE_DIR set, the fixture file of that path instead.
github_api() {
    local path=$1
    local file

    if [ -n "$FIXTURE_DIR" ]; then
        file="$FIXTURE_DIR/$(tr '/?=&' '____' <<< "$path").json"
        if [ -f "$file" ]; then
            cat "$file"
        fi
        return 0
    fi

    gh api "$path" 2> /dev/null || true
}

# latest_release <owner/repo>: `<tag> <commit sha> <date>` of the latest
# release, the tag dereferenced when annotated; nothing when any piece is
# missing.
latest_release() {
    local repo=$1
    local release tag date reference type sha

    release=$(github_api "repos/$repo/releases/latest")
    tag=$(jq -r '.tag_name // empty' <<< "${release:-null}")
    date=$(jq -r '.published_at // empty' <<< "${release:-null}" | cut -c1-10)
    if [ -z "$tag" ]; then
        return 0
    fi

    reference=$(github_api "repos/$repo/git/ref/tags/$tag")
    type=$(jq -r '.object.type // empty' <<< "${reference:-null}")
    sha=$(jq -r '.object.sha // empty' <<< "${reference:-null}")
    if [ "$type" = tag ] && [ -n "$sha" ]; then
        sha=$(github_api "repos/$repo/git/tags/$sha" | jq -r '.object.sha // empty')
    fi
    if [ -z "$sha" ]; then
        return 0
    fi

    echo "$tag $sha $date"
}

# sha_is_commit_of <owner/repo> <sha>: status 0 when the sha is a commit of
# that repository. A sha that belongs to a fork is not a pin (GitHub docs,
# "Security hardening for GitHub Actions").
sha_is_commit_of() {
    local repo=$1
    local sha=$2
    local found

    found=$(github_api "repos/$repo/commits/$sha" | jq -r '.sha // empty')
    [ -n "$found" ]
}

# --- the pins in the workflows ------------------------------------------------
# The greps below may match nothing (a class with no item): `|| true` keeps an
# empty set from stopping the script under pipefail (docs/gotchas.md).

# uses_lines <workflows dir>: every pinned `uses:` line, once each.
uses_lines() {
    local dir=$1

    { grep -hoE "$PINNED_USES" "$dir"/*.yml || true; } | sort -u
}

# parse_uses_line <line>: sets uses (owner/repo[/path]@sha), repo, sha and
# comment (the version after `#`, or empty) in the caller.
parse_uses_line() {
    local line=$1

    uses=${line#uses: }
    uses=${uses%%#*}
    uses=${uses% }
    repo=$(cut -d/ -f1,2 <<< "${uses%%@*}")
    sha=${uses##*@}
    comment=$(sed -n 's/.*# *//p' <<< "$line")
}

# binary_pins <workflow key>: every version pinned under that key, once each.
binary_pins() {
    local key=$1

    { grep -hoE "^ *$key: *\"?v?[0-9][0-9.]*\"?" "$WORKFLOWS"/*.yml || true; } \
        | sed -E 's/.*: *"?(v?[0-9.]+)"?/\1/' | sort -u
}

# runner_labels: every `runs-on:` label, once each. For `${{ vars.X ||
# 'label' }}` the fallback is reported: it is what runs when the variable is
# unset, so it is the one the runner-images README must still list.
runner_labels() {
    { grep -hoE "$RUNS_ON" "$WORKFLOWS"/*.yml || true; } \
        | sed -E "s/.*'([a-z0-9.-]+)'.*/\\1/; s/.*: *//" | sort -u
}

# --- the table ----------------------------------------------------------------

# print_row <class> <item> <pinned> <latest> <state> <detail>: one table row.
print_row() {
    printf '%-8s | %-45s | %-14s | %-14s | %-8s | %s\n' "$@"
}

# check_actions: one row per pinned action: OK, STALE when the sha or the
# version comment is behind the latest release, FOREIGN when the sha is not a
# commit of the repository, UNKNOWN when no release is readable.
check_actions() {
    local line uses repo sha comment latest tag latest_sha date

    uses_lines "$WORKFLOWS" | while IFS= read -r line; do
        parse_uses_line "$line"

        latest=$(latest_release "$repo")
        if [ -z "$latest" ]; then
            print_row action "$uses" "${comment:-?}" "?" UNKNOWN "no release readable for $repo"
            continue
        fi
        read -r tag latest_sha date <<< "$latest"

        if ! sha_is_commit_of "$repo" "$sha"; then
            print_row action "$uses" "${comment:-?}" "$tag" FOREIGN "$sha is not a commit of $repo"
        elif [ "$sha" = "$latest_sha" ] && [ "$comment" = "$tag" ]; then
            print_row action "$uses" "$comment" "$tag" OK "$date"
        elif [ "$sha" = "$latest_sha" ]; then
            print_row action "$uses" "${comment:-?}" "$tag" STALE \
                "comment says '${comment:-}', tag is $tag"
        else
            print_row action "$uses" "${comment:-?}" "$tag" STALE \
                "latest $tag = $latest_sha ($date)"
        fi
    done
}

# check_binaries: one row per installed binary, its pinned versions against
# the latest release; ORAS_VERSION carries no v (the release asset names), so
# the versions are compared without it.
check_binaries() {
    local pair key repo pinned latest tag latest_sha date

    for pair in $BINARIES; do
        key=${pair%%=*}
        repo=${pair#*=}
        pinned=$(binary_pins "$key" | tr '\n' ' ')
        pinned=${pinned% }
        if [ -z "$pinned" ]; then
            continue
        fi

        latest=$(latest_release "$repo")
        if [ -z "$latest" ]; then
            print_row binary "$key ($repo)" "$pinned" "?" UNKNOWN "no release readable for $repo"
            continue
        fi
        read -r tag latest_sha date <<< "$latest"

        if [ "${pinned#v}" = "${tag#v}" ]; then
            print_row binary "$key ($repo)" "$pinned" "$tag" OK "$date"
        else
            print_row binary "$key ($repo)" "$pinned" "$tag" STALE "latest $tag ($date)"
        fi
    done
}

# check_runners: one row per runner label, looked up in the table of the
# actions/runner-images README: OK when listed (preview noted), STALE when
# absent or deprecated, UNKNOWN when the README is not readable.
check_runners() {
    local readme label readme_row

    readme=$(github_api repos/actions/runner-images/readme | jq -r '.content // empty' \
        | base64 -d 2> /dev/null || true)

    runner_labels | while IFS= read -r label; do
        if [ -z "$readme" ]; then
            print_row runner "$label" "-" "?" UNKNOWN "README of actions/runner-images not readable"
            continue
        fi

        readme_row=$(grep -E "^\| .*\`${label}\`" <<< "$readme" | head -n1 || true)
        if [ -z "$readme_row" ]; then
            print_row runner "$label" "-" "-" STALE "label not in the README table"
        elif grep -q 'preview' <<< "$readme_row"; then
            print_row runner "$label" "-" "-" OK "listed, still marked preview"
        elif grep -q 'deprecated' <<< "$readme_row"; then
            print_row runner "$label" "-" "-" STALE "listed as deprecated"
        else
            print_row runner "$label" "-" "-" OK "listed"
        fi
    done
}

# check_workflows: one row per workflow of the repository with its state;
# GitHub disables a public repository's cron after 60 days without a commit.
check_workflows() {
    local workflows path state
    local enable="re-enable: gh api -X PUT repos/$REPO/actions/workflows/<id>/enable"

    workflows=$(github_api "repos/$REPO/actions/workflows")
    if [ -z "$(jq -r '.workflows // empty' <<< "${workflows:-null}")" ]; then
        print_row workflow "$REPO" "-" "-" UNKNOWN "workflow list not readable"
        return 0
    fi

    jq -r '.workflows[] | "\(.path)\t\(.state)"' <<< "$workflows" \
        | while IFS=$'\t' read -r path state; do
            if [ "$state" = active ]; then
                print_row workflow "$path" "-" "-" OK "$state"
            else
                print_row workflow "$path" "-" "-" DISABLED "$state ($enable)"
            fi
        done
}

# check_issues: one row per `owner/repo#N` cited in a workflow: OK while open,
# CLOSED when the flag chosen because of it is due for review, UNKNOWN when
# the issue is not readable.
check_issues() {
    local reference repo number issue state date

    { grep -hoE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+' "$WORKFLOWS"/*.yml || true; } | sort -u \
        | while IFS= read -r reference; do
            repo=${reference%%#*}
            number=${reference##*#}
            issue=$(github_api "repos/$repo/issues/$number")
            state=$(jq -r '.state // empty' <<< "${issue:-null}")
            date=$(jq -r '.updated_at // empty' <<< "${issue:-null}" | cut -c1-10)

            case "$state" in
                open)
                    print_row issue "$reference" "-" "-" OK "open, updated $date"
                    ;;
                closed)
                    print_row issue "$reference" "-" "-" CLOSED \
                        "closed $date: review the flag chosen because of it"
                    ;;
                *)
                    print_row issue "$reference" "-" "-" UNKNOWN "issue not readable"
                    ;;
            esac
        done
}

check() {
    print_row class item pinned latest state detail
    print_row -------- --------------------------------------------- -------------- \
        -------------- -------- ------

    check_actions
    check_binaries
    check_runners
    check_workflows
    check_issues
}

# --- the rewrite --------------------------------------------------------------

REWRITTEN=0

# pin_comment_names_tag <sha> <tag>: status 0 when some workflow pins that sha
# with a version comment naming that tag.
pin_comment_names_tag() {
    local sha=$1
    local tag=$2

    grep -qE "@${sha} *# *${tag//./\\.}( |$)" "$WORKFLOWS"/*.yml
}

# apply_actions: every pinned action whose sha or version comment is behind
# the latest release is rewritten in place to `@<latest sha> # <tag>`; a
# foreign sha and an unreadable release are left as they are.
apply_actions() {
    local line uses repo sha comment latest tag latest_sha date

    while IFS= read -r line; do
        parse_uses_line "$line"

        latest=$(latest_release "$repo" || true)
        if [ -z "$latest" ]; then
            continue
        fi
        read -r tag latest_sha date <<< "$latest"

        if ! sha_is_commit_of "$repo" "$sha"; then
            continue
        fi
        if [ "$sha" = "$latest_sha" ] && pin_comment_names_tag "$sha" "$tag"; then
            continue
        fi

        sed -i -E "s|(uses: ${uses%%@*}@)${sha}( *# *[^ ]+)?|\1${latest_sha} # ${tag}|" \
            "$WORKFLOWS"/*.yml
        echo "applied: ${uses%%@*} -> ${latest_sha} # ${tag}"
        REWRITTEN=$((REWRITTEN + 1))
    done < <(uses_lines "$WORKFLOWS")
}

# apply_binaries: every installed binary pinned behind the latest release is
# rewritten to it, in the form the workflow already uses (with or without v).
apply_binaries() {
    local pair key repo pinned latest tag latest_sha date new

    for pair in $BINARIES; do
        key=${pair%%=*}
        repo=${pair#*=}
        pinned=$(binary_pins "$key" | head -n1)
        if [ -z "$pinned" ]; then
            continue
        fi

        latest=$(latest_release "$repo" || true)
        if [ -z "$latest" ]; then
            continue
        fi
        read -r tag latest_sha date <<< "$latest"
        if [ "${pinned#v}" = "${tag#v}" ]; then
            continue
        fi

        new=$tag
        if [[ "$pinned" != v* ]]; then
            new=${tag#v}
        fi
        sed -i -E "s|^( *${key}: *\"?)${pinned//./\\.}(\"?)|\1${new}\2|" "$WORKFLOWS"/*.yml
        echo "applied: ${key} ${pinned} -> ${new}"
        REWRITTEN=$((REWRITTEN + 1))
    done
}

apply() {
    apply_actions
    apply_binaries

    echo "apply done: $REWRITTEN pins rewritten" \
        "(runners, workflow states and issues are never rewritten)"
}

# --- self-test ----------------------------------------------------------------

# self_test_write_workflow <dir>: one workflow with a pin per verdict the
# table can print: stale, current, vanished and forked actions, two binary
# pins, a deprecated runner, a cited issue and a runs-on with a vars fallback.
self_test_write_workflow() {
    local dir=$1

    cat > "$dir/a.yml" << 'EOF'
jobs:
  x:
    runs-on: ubuntu-26.04
    steps:
      - uses: acme/old@1111111111111111111111111111111111111111 # v1.0.0
      - uses: acme/current@2222222222222222222222222222222222222222 # v2.0.0
      - uses: acme/vanished@3333333333333333333333333333333333333333 # v3.0.0
      - uses: acme/forked@4444444444444444444444444444444444444444 # v2.0.0
      - uses: acme/tool@5555555555555555555555555555555555555555 # v0.1.0
        with:
          cosign-release: v3.1.2
      - uses: acme/tool@5555555555555555555555555555555555555555 # v0.1.0
        env:
          ORAS_VERSION: 0.9.0
  y:
    runs-on: ubuntu-18.04
    # see acme/lib#7
  z:
    runs-on: ${{ vars.BUILD_RUNNER || 'ubuntu-16.04' }}
EOF
}

# self_test_write_fixture <dir> <api path> <json>: the file github_api reads
# for that path.
self_test_write_fixture() {
    local dir=$1
    local path=$2
    local json=$3

    echo "$json" > "$dir/$(tr '/?=&' '____' <<< "$path").json"
}

# self_test_write_release <dir> <owner/repo> <tag> <date> <object json>: the
# latest release of a repository and what its tag points at.
self_test_write_release() {
    local dir=$1
    local repo=$2
    local tag=$3
    local date=$4
    local object=$5

    self_test_write_fixture "$dir" "repos/$repo/releases/latest" \
        "{\"tag_name\":\"$tag\",\"published_at\":\"${date}T00:00:00Z\"}"
    self_test_write_fixture "$dir" "repos/$repo/git/ref/tags/$tag" "{\"object\":$object}"
}

# self_test_write_commit <dir> <owner/repo> <sha>: the commit lookup that makes
# a sha one of the repository's own.
self_test_write_commit() {
    local dir=$1
    local repo=$2
    local sha=$3

    self_test_write_fixture "$dir" "repos/$repo/commits/$sha" "{\"sha\":\"$sha\"}"
}

# self_test_write_fixtures <dir>: the API answers behind the workflow: acme/old
# has a newer release, acme/current's annotated tag resolves to its pin,
# acme/vanished has no release, acme/forked's pin is not its commit, the two
# binaries have newer releases, the README lists ubuntu-26.04 as preview, one
# workflow is disabled and the cited issue is closed.
self_test_write_fixtures() {
    local dir=$1
    local sha_1=1111111111111111111111111111111111111111
    local sha_2=2222222222222222222222222222222222222222
    local sha_4=4444444444444444444444444444444444444444
    local sha_5=5555555555555555555555555555555555555555
    local sha_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    local annotated=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
    local readme_row='| Ubuntu 26.04 ![preview](x) | x64 | `ubuntu-26.04` | [u] |'
    local workflows='[{"path":".github/workflows/a.yml","state":"active"}'
    workflows+=',{"path":".github/workflows/b.yml","state":"disabled_inactivity"}]'

    self_test_write_release "$dir" acme/old v1.1.0 2026-08-01 \
        "{\"type\":\"commit\",\"sha\":\"$sha_a\"}"
    self_test_write_commit "$dir" acme/old "$sha_1"

    self_test_write_release "$dir" acme/current v2.0.0 2026-08-02 \
        "{\"type\":\"tag\",\"sha\":\"$annotated\"}"
    self_test_write_fixture "$dir" "repos/acme/current/git/tags/$annotated" \
        "{\"object\":{\"sha\":\"$sha_2\"}}"
    self_test_write_commit "$dir" acme/current "$sha_2"

    self_test_write_release "$dir" acme/forked v2.0.0 2026-08-02 \
        "{\"type\":\"commit\",\"sha\":\"$sha_4\"}"

    self_test_write_release "$dir" acme/tool v0.1.0 2026-08-02 \
        "{\"type\":\"commit\",\"sha\":\"$sha_5\"}"
    self_test_write_commit "$dir" acme/tool "$sha_5"

    self_test_write_release "$dir" sigstore/cosign v3.1.3 2026-08-06 \
        '{"type":"commit","sha":"11926fa5bbbbde47e88fc006b625a17769b743b2"}'
    self_test_write_release "$dir" oras-project/oras v1.0.0 2026-08-27 \
        '{"type":"commit","sha":"6666666666666666666666666666666666666666"}'

    self_test_write_fixture "$dir" repos/actions/runner-images/readme \
        "{\"content\":\"$(printf '%s\n' "$readme_row" | base64 -w0)\"}"
    self_test_write_fixture "$dir" repos/acme/repo/actions/workflows \
        "{\"workflows\":$workflows}"
    self_test_write_fixture "$dir" repos/acme/lib/issues/7 \
        '{"state":"closed","updated_at":"2026-07-01T00:00:00Z"}'
}

# self_test_expect_row <table> <pattern>: the table holds a row matching the
# pattern, or the self-test fails showing the table.
self_test_expect_row() {
    local table=$1
    local pattern=$2

    if ! grep -qE "$pattern" <<< "$table"; then
        fail_self_test "expected a row matching '$pattern', got:"$'\n'"$table"
    fi
}

# self_test_check <dir>: the table on the fixtures shows every verdict once.
self_test_check() {
    local dir=$1
    local table

    table=$(FIXTURE_DIR=$dir/fx WORKFLOWS=$dir/wf REPO=acme/repo check)

    self_test_expect_row "$table" '^action +\| acme/old@1111.* \| STALE '
    self_test_expect_row "$table" '^action +\| acme/current@2222.* \| OK '
    self_test_expect_row "$table" '^action +\| acme/vanished@3333.* \| UNKNOWN '
    self_test_expect_row "$table" '^action +\| acme/forked@4444.* \| FOREIGN '
    self_test_expect_row "$table" '^binary +\| cosign-release .* \| v3.1.2 +\| v3.1.3 +\| STALE '
    self_test_expect_row "$table" '^binary +\| ORAS_VERSION .* \| 0.9.0 +\| v1.0.0 +\| STALE '
    self_test_expect_row "$table" \
        '^runner +\| ubuntu-26.04 .* \| OK +\| listed, still marked preview'
    self_test_expect_row "$table" '^runner +\| ubuntu-18.04 .* \| STALE '
    self_test_expect_row "$table" '^runner +\| ubuntu-16.04 .* \| STALE '
    self_test_expect_row "$table" '^workflow +\| .github/workflows/b.yml .* \| DISABLED '
    self_test_expect_row "$table" '^issue +\| acme/lib#7 .* \| CLOSED '
}

# self_test_expect_pin <workflow> <text> <what>: the workflow holds the text,
# or the self-test fails naming what apply got wrong.
self_test_expect_pin() {
    local workflow=$1
    local text=$2
    local what=$3

    if ! grep -q "$text" "$workflow"; then
        fail_self_test "apply $what"
    fi
}

# self_test_apply <dir>: apply rewrites the stale action and the two binaries,
# in the form each already uses, and spares the current and the foreign pin.
self_test_apply() {
    local dir=$1
    local workflow=$dir/wf/a.yml

    FIXTURE_DIR=$dir/fx WORKFLOWS=$dir/wf REPO=acme/repo apply > /dev/null

    self_test_expect_pin "$workflow" \
        'acme/old@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.1.0' \
        "did not rewrite the stale pin"
    self_test_expect_pin "$workflow" \
        'acme/current@2222222222222222222222222222222222222222 # v2.0.0' \
        "touched a current pin"
    self_test_expect_pin "$workflow" \
        'acme/forked@4444444444444444444444444444444444444444 # v2.0.0' \
        "touched a foreign pin"
    self_test_expect_pin "$workflow" 'cosign-release: v3.1.3' \
        "did not rewrite the binary version"
    self_test_expect_pin "$workflow" 'ORAS_VERSION: 1.0.0' \
        "did not keep the v-less form of the oras version"
}

self_test() {
    local dir

    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    mkdir -p "$dir/wf" "$dir/fx"
    self_test_write_workflow "$dir/wf"
    self_test_write_fixtures "$dir/fx"

    self_test_check "$dir"
    self_test_apply "$dir"

    echo "self-test ok: 11 verdicts on fixtures (STALE, OK, UNKNOWN, FOREIGN, DISABLED, CLOSED;" \
        "a runs-on with a vars fallback read), apply rewrote 3 pins and spared 2"
}

# --- main ---------------------------------------------------------------------

case "${1:---check}" in
    --check)
        check
        ;;
    --apply)
        apply
        ;;
    --self-test)
        self_test
        ;;
    *)
        exit_with_error "usage: refresh-pins.sh [--check | --apply | --self-test]"
        ;;
esac
