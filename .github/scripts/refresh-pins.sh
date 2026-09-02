#!/usr/bin/env bash
# The pin refresh of the repository, by hand and never by a bot: one table row
# per action, binary, runner, workflow state and cited issue. Lookups go
# through gh, and FIXTURE_DIR replaces them with files for the self-test.
#
#   refresh-pins.sh [--check]     the table; exit 0 always, one row per item
#   refresh-pins.sh --apply       rewrite the STALE actions and binaries;
#                                 runners, workflow states and issues are
#                                 reported only
#   refresh-pins.sh --self-test   prove the verdicts on fixtures, offline
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

WORKFLOWS=${WORKFLOWS:-.github/workflows}
FIXTURE_DIR=${FIXTURE_DIR:-}
# binary pins: <workflow key>=<owner/repo of the binary>
BINARIES="cosign-release=sigstore/cosign syft-version=anchore/syft ORAS_VERSION=oras-project/oras"

api() {
    local path=$1 file
    if [ -n "$FIXTURE_DIR" ]; then
        file="$FIXTURE_DIR/$(tr '/?=&' '____' <<< "$path").json"
        [ -f "$file" ] && cat "$file"
        return 0
    fi
    gh api "$path" 2> /dev/null || true
}

# "<tag> <sha> <date>", the tag dereferenced when annotated, empty on any
# missing piece.
latest_release() {
    local repo=$1 json tag date ref type sha
    json=$(api "repos/$repo/releases/latest")
    tag=$(jq -r '.tag_name // empty' <<< "${json:-null}")
    date=$(jq -r '.published_at // empty' <<< "${json:-null}" | cut -c1-10)
    [ -n "$tag" ] || return 0
    ref=$(api "repos/$repo/git/ref/tags/$tag")
    type=$(jq -r '.object.type // empty' <<< "${ref:-null}")
    sha=$(jq -r '.object.sha // empty' <<< "${ref:-null}")
    if [ "$type" = tag ] && [ -n "$sha" ]; then
        sha=$(api "repos/$repo/git/tags/$sha" | jq -r '.object.sha // empty')
    fi
    [ -n "$sha" ] || return 0
    echo "$tag $sha $date"
}

# A sha that belongs to a fork is not a pin (GitHub docs, "Security hardening
# for GitHub Actions").
in_repo() {
    [ -n "$(api "repos/$1/commits/$2" | jq -r '.sha // empty')" ]
}

# The greps below may match nothing (a class with no item): `|| true` keeps
# an empty set from killing the script under pipefail (docs/gotchas.md).
uses_lines() {
    { grep -hoE 'uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[A-Za-z0-9_./-]+)?@[0-9a-f]{40}( *# *[^ ]+)?' "$1"/*.yml || true; } | sort -u
}

binary_pins() {
    { grep -hoE "^ *$1: *\"?v?[0-9][0-9.]*\"?" "$WORKFLOWS"/*.yml || true; } | sed -E 's/.*: *"?(v?[0-9.]+)"?/\1/' | sort -u
}

row() {
    printf '%-8s | %-45s | %-14s | %-14s | %-8s | %s\n' "$@"
}

check_actions() {
    local line uses repo sha comment latest tag lsha date
    uses_lines "$WORKFLOWS" | while IFS= read -r line; do
        uses=${line#uses: }
        uses=${uses%%#*}
        uses=${uses% }
        repo=$(cut -d/ -f1,2 <<< "${uses%%@*}")
        sha=${uses##*@}
        comment=$(sed -n 's/.*# *//p' <<< "$line")
        latest=$(latest_release "$repo")
        if [ -z "$latest" ]; then
            row action "$uses" "${comment:-?}" "?" UNKNOWN "no release readable for $repo"
            continue
        fi
        read -r tag lsha date <<< "$latest"
        if ! in_repo "$repo" "$sha"; then
            row action "$uses" "${comment:-?}" "$tag" FOREIGN "$sha is not a commit of $repo"
        elif [ "$sha" = "$lsha" ] && [ "$comment" = "$tag" ]; then
            row action "$uses" "$comment" "$tag" OK "$date"
        elif [ "$sha" = "$lsha" ]; then
            row action "$uses" "${comment:-?}" "$tag" STALE "comment says '${comment:-}', tag is $tag"
        else
            row action "$uses" "${comment:-?}" "$tag" STALE "latest $tag = $lsha ($date)"
        fi
    done
}

check_binaries() {
    local pair key repo pinned latest tag lsha date
    for pair in $BINARIES; do
        key=${pair%%=*}
        repo=${pair#*=}
        pinned=$(binary_pins "$key" | tr '\n' ' ')
        pinned=${pinned% }
        [ -n "$pinned" ] || continue
        latest=$(latest_release "$repo")
        if [ -z "$latest" ]; then
            row binary "$key ($repo)" "$pinned" "?" UNKNOWN "no release readable for $repo"
            continue
        fi
        read -r tag lsha date <<< "$latest"
        # ORAS_VERSION carries no v (the release asset names): compare without it.
        if [ "${pinned#v}" = "${tag#v}" ]; then
            row binary "$key ($repo)" "$pinned" "$tag" OK "$date"
        else
            row binary "$key ($repo)" "$pinned" "$tag" STALE "latest $tag ($date)"
        fi
    done
}

# The label is a literal, or the quoted fallback of `${{ vars.X || 'label' }}`
# (the build jobs read vars.BUILD_RUNNER first): the fallback is what runs
# when the variable is unset, so it is the one the README must still list.
runner_labels() {
    { grep -hoE "^ *runs-on: *([a-z0-9.-]+|\\\$\\{\\{ *vars\\.[A-Za-z_]+ *\\|\\| *'[a-z0-9.-]+' *\\}\\})" "$WORKFLOWS"/*.yml || true; } \
        | sed -E "s/.*'([a-z0-9.-]+)'.*/\\1/; s/.*: *//" | sort -u
}

check_runners() {
    local readme label rowtxt
    readme=$(api repos/actions/runner-images/readme | jq -r '.content // empty' | base64 -d 2> /dev/null || true)
    runner_labels | while IFS= read -r label; do
        if [ -z "$readme" ]; then
            row runner "$label" "-" "?" UNKNOWN "README of actions/runner-images not readable"
            continue
        fi
        rowtxt=$(grep -E "^\| .*\`${label}\`" <<< "$readme" | head -n1 || true)
        if [ -z "$rowtxt" ]; then
            row runner "$label" "-" "-" STALE "label not in the README table"
        elif grep -q 'preview' <<< "$rowtxt"; then
            row runner "$label" "-" "-" OK "listed, still marked preview"
        elif grep -q 'deprecated' <<< "$rowtxt"; then
            row runner "$label" "-" "-" STALE "listed as deprecated"
        else
            row runner "$label" "-" "-" OK "listed"
        fi
    done
}

check_workflows() {
    local json
    json=$(api "repos/$REPO/actions/workflows")
    if [ -z "$(jq -r '.workflows // empty' <<< "${json:-null}")" ]; then
        row workflow "$REPO" "-" "-" UNKNOWN "workflow list not readable"
        return 0
    fi
    jq -r '.workflows[] | "\(.path)\t\(.state)"' <<< "$json" | while IFS=$'\t' read -r path state; do
        if [ "$state" = active ]; then
            row workflow "$path" "-" "-" OK "$state"
        else
            row workflow "$path" "-" "-" DISABLED "$state (re-enable: gh api -X PUT repos/$REPO/actions/workflows/<id>/enable)"
        fi
    done
}

check_issues() {
    local ref repo number json state date
    { grep -hoE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+' "$WORKFLOWS"/*.yml || true; } | sort -u | while IFS= read -r ref; do
        repo=${ref%%#*}
        number=${ref##*#}
        json=$(api "repos/$repo/issues/$number")
        state=$(jq -r '.state // empty' <<< "${json:-null}")
        date=$(jq -r '.updated_at // empty' <<< "${json:-null}" | cut -c1-10)
        case "$state" in
            open) row issue "$ref" "-" "-" OK "open, updated $date" ;;
            closed) row issue "$ref" "-" "-" CLOSED "closed $date: review the flag chosen because of it" ;;
            *) row issue "$ref" "-" "-" UNKNOWN "issue not readable" ;;
        esac
    done
}

check() {
    row class item pinned latest state detail
    row -------- --------------------------------------------- -------------- -------------- -------- ------
    check_actions
    check_binaries
    check_runners
    check_workflows
    check_issues
}

apply() {
    local line uses repo sha latest tag lsha date pair key pinned new n=0
    while IFS= read -r line; do
        uses=${line#uses: }
        uses=${uses%%#*}
        uses=${uses% }
        repo=$(cut -d/ -f1,2 <<< "${uses%%@*}")
        sha=${uses##*@}
        latest=$(latest_release "$repo") || true
        [ -n "$latest" ] || continue
        read -r tag lsha date <<< "$latest"
        in_repo "$repo" "$sha" || continue
        if [ "$sha" != "$lsha" ] || ! grep -qE "@${sha} *# *${tag//./\\.}( |$)" "$WORKFLOWS"/*.yml; then
            sed -i -E "s|(uses: ${uses%%@*}@)${sha}( *# *[^ ]+)?|\1${lsha} # ${tag}|" "$WORKFLOWS"/*.yml
            echo "applied: ${uses%%@*} -> ${lsha} # ${tag}"
            n=$((n + 1))
        fi
    done < <(uses_lines "$WORKFLOWS")
    for pair in $BINARIES; do
        key=${pair%%=*}
        repo=${pair#*=}
        pinned=$(binary_pins "$key" | head -n1)
        [ -n "$pinned" ] || continue
        latest=$(latest_release "$repo") || true
        [ -n "$latest" ] || continue
        read -r tag lsha date <<< "$latest"
        if [ "${pinned#v}" != "${tag#v}" ]; then
            new=$tag
            [[ "$pinned" == v* ]] || new=${tag#v}
            sed -i -E "s|^( *${key}: *\"?)${pinned//./\\.}(\"?)|\1${new}\2|" "$WORKFLOWS"/*.yml
            echo "applied: ${key} ${pinned} -> ${new}"
            n=$((n + 1))
        fi
    done
    echo "apply done: $n pins rewritten (runners, workflow states and issues are never rewritten)"
}

self_test() {
    local dir out
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    mkdir -p "$dir/wf" "$dir/fx"
    # One fixture per verdict the table can print.
    cat > "$dir/wf/a.yml" << 'EOF'
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
    echo '{"tag_name":"v1.1.0","published_at":"2026-08-01T00:00:00Z"}' > "$dir/fx/repos_acme_old_releases_latest.json"
    echo '{"object":{"type":"commit","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' > "$dir/fx/repos_acme_old_git_ref_tags_v1.1.0.json"
    echo '{"sha":"1111111111111111111111111111111111111111"}' > "$dir/fx/repos_acme_old_commits_1111111111111111111111111111111111111111.json"
    echo '{"tag_name":"v2.0.0","published_at":"2026-08-02T00:00:00Z"}' > "$dir/fx/repos_acme_current_releases_latest.json"
    echo '{"object":{"type":"tag","sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}}' > "$dir/fx/repos_acme_current_git_ref_tags_v2.0.0.json"
    echo '{"object":{"sha":"2222222222222222222222222222222222222222"}}' > "$dir/fx/repos_acme_current_git_tags_deadbeefdeadbeefdeadbeefdeadbeefdeadbeef.json"
    echo '{"sha":"2222222222222222222222222222222222222222"}' > "$dir/fx/repos_acme_current_commits_2222222222222222222222222222222222222222.json"
    echo '{"tag_name":"v2.0.0","published_at":"2026-08-02T00:00:00Z"}' > "$dir/fx/repos_acme_forked_releases_latest.json"
    echo '{"object":{"type":"commit","sha":"4444444444444444444444444444444444444444"}}' > "$dir/fx/repos_acme_forked_git_ref_tags_v2.0.0.json"
    echo '{"tag_name":"v0.1.0","published_at":"2026-08-02T00:00:00Z"}' > "$dir/fx/repos_acme_tool_releases_latest.json"
    echo '{"object":{"type":"commit","sha":"5555555555555555555555555555555555555555"}}' > "$dir/fx/repos_acme_tool_git_ref_tags_v0.1.0.json"
    echo '{"sha":"5555555555555555555555555555555555555555"}' > "$dir/fx/repos_acme_tool_commits_5555555555555555555555555555555555555555.json"
    echo '{"tag_name":"v3.1.3","published_at":"2026-08-06T00:00:00Z"}' > "$dir/fx/repos_sigstore_cosign_releases_latest.json"
    echo '{"object":{"type":"commit","sha":"11926fa5bbbbde47e88fc006b625a17769b743b2"}}' > "$dir/fx/repos_sigstore_cosign_git_ref_tags_v3.1.3.json"
    echo '{"tag_name":"v1.0.0","published_at":"2026-08-27T00:00:00Z"}' > "$dir/fx/repos_oras-project_oras_releases_latest.json"
    echo '{"object":{"type":"commit","sha":"6666666666666666666666666666666666666666"}}' > "$dir/fx/repos_oras-project_oras_git_ref_tags_v1.0.0.json"
    printf '{"content":"%s"}' "$(printf '| Ubuntu 26.04 ![preview](x) | x64 | `ubuntu-26.04` | [u] |\n' | base64 -w0)" > "$dir/fx/repos_actions_runner-images_readme.json"
    echo '{"workflows":[{"path":".github/workflows/a.yml","state":"active"},{"path":".github/workflows/b.yml","state":"disabled_inactivity"}]}' \
        > "$dir/fx/repos_acme_repo_actions_workflows.json"
    echo '{"state":"closed","updated_at":"2026-07-01T00:00:00Z"}' > "$dir/fx/repos_acme_lib_issues_7.json"
    out=$(FIXTURE_DIR=$dir/fx WORKFLOWS=$dir/wf REPO=acme/repo check)
    expect() {
        grep -qE "$1" <<< "$out" || fail "self-test: expected a row matching '$1', got:"$'\n'"$out"
    }
    expect '^action +\| acme/old@1111.* \| STALE '
    expect '^action +\| acme/current@2222.* \| OK '
    expect '^action +\| acme/vanished@3333.* \| UNKNOWN '
    expect '^action +\| acme/forked@4444.* \| FOREIGN '
    expect '^binary +\| cosign-release .* \| v3.1.2 +\| v3.1.3 +\| STALE '
    expect '^binary +\| ORAS_VERSION .* \| 0.9.0 +\| v1.0.0 +\| STALE '
    expect '^runner +\| ubuntu-26.04 .* \| OK +\| listed, still marked preview'
    expect '^runner +\| ubuntu-18.04 .* \| STALE '
    expect '^runner +\| ubuntu-16.04 .* \| STALE '
    expect '^workflow +\| .github/workflows/b.yml .* \| DISABLED '
    expect '^issue +\| acme/lib#7 .* \| CLOSED '
    FIXTURE_DIR=$dir/fx WORKFLOWS=$dir/wf REPO=acme/repo apply > /dev/null
    grep -q 'acme/old@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.1.0' "$dir/wf/a.yml" || fail "self-test: apply did not rewrite the stale pin"
    grep -q 'acme/current@2222222222222222222222222222222222222222 # v2.0.0' "$dir/wf/a.yml" || fail "self-test: apply touched a current pin"
    grep -q 'acme/forked@4444444444444444444444444444444444444444 # v2.0.0' "$dir/wf/a.yml" || fail "self-test: apply touched a foreign pin"
    grep -q 'cosign-release: v3.1.3' "$dir/wf/a.yml" || fail "self-test: apply did not rewrite the binary version"
    grep -q 'ORAS_VERSION: 1.0.0' "$dir/wf/a.yml" || fail "self-test: apply did not keep the v-less form of the oras version"
    echo "self-test ok: 11 verdicts on fixtures (STALE, OK, UNKNOWN, FOREIGN, DISABLED, CLOSED; a runs-on with a vars fallback read), apply rewrote 3 pins and spared 2"
}

case "${1:---check}" in
    --check) check ;;
    --apply) apply ;;
    --self-test) self_test ;;
    *) fail "usage: refresh-pins.sh [--check | --apply | --self-test]" ;;
esac
