#!/usr/bin/env bash
# The body and the title of a GitHub Release, from what the run resolved: the
# base version and the kernel from the base's labels, the package diff from
# the SBOMs attached to the images, the commits since the previous release.
# The previous release comes from `gh release list`, never from a manifest's
# RepoTags, which an orphan tag would hijack. Every gap (no previous release,
# a flavour it lacked, a missing SBOM, a rewritten history) is stated in the
# notes.
#
# Usage: changelog.sh release --release-tag <tag> --out <changelog.md> <env-file>...
#          --release-tag <tag>   the tag being released, <fedora>.<yyyymmdd>[.N]
#          --out <changelog.md>  where the notes are written
#          <env-file>...         one per flavour, from the build job:
#                                image_name, digest, base_name, base_digest
#        changelog.sh --self-test
# Output: the release title on stdout, `<tag>: Stable (Bazzite <version>)`;
#   the notes in the --out file; `changelog: no package diff for <tag>: …` on
#   stderr when no flavour could be compared with the previous release.
# Exit status: 0 notes written; 1 on a bad argument, an env file refused, an
#   image that cannot be inspected, an SBOM that cannot be read or a release
#   list gh cannot read. A transport error is never taken for an absence.
# Needs skopeo, oras, jq, gh (GH_TOKEN) and git with the history: the release
# workflow fetches 500 commits so the previous release's revision is reached.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SBOM_TYPE=application/vnd.spdx+json
# One row per RPM name, except gpg-pubkey: one name for every imported key.
SBOM_ROW='.artifacts[] | select(.type == "rpm")
    | "\(if .name == "gpg-pubkey" then "gpg-pubkey \(.version)" else .name end)\t\(.version)"'

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# --- the release being described ----------------------------------------------
#
# Set by parse_arguments, find_previous_tag, read_flavours and
# find_previous_revision; read by the write_* functions, but NOTES_FILE by
# release and ENV_FILES by read_flavours. The arrays hold one entry per env
# file, in the order the files were given.

RELEASE_TAG=""
NOTES_FILE=""
ENV_FILES=()
BASE_VERSION=""
PREVIOUS_TAG=""
PREVIOUS_REVISION=""
IMAGE_NAMES=()
IMAGE_DIGESTS=()
BASE_NAMES=()
BASE_DIGESTS=()
KERNELS=()

# Appended by write_package_section and write_package_diff, read by write_packages.
PACKAGE_DIFF_GAPS=""

# --- image labels -------------------------------------------------------------

# inspect_labels <image@digest>: the labels of that image as one JSON object.
inspect_labels() {
    local reference=$1
    local error_file=$WORK_DIR/labels.err
    local manifest error

    if ! manifest=$(skopeo inspect --retry-times 3 --no-tags "docker://$reference" \
        2> "$error_file"); then
        error=$(< "$error_file")
        print_error "skopeo inspect $reference: ${error//$'\n'/ }"
        return 1
    fi

    jq -c '.Labels' <<< "$manifest"
}

# label_of <labels json> <label> <fallback>: the label's value, the fallback
# when the image does not carry it.
label_of() {
    local labels_json=$1
    local label=$2
    local fallback=$3

    jq -r --arg label "$label" --arg fallback "$fallback" '.[$label] // $fallback' \
        <<< "$labels_json"
}

# --- the previous release -----------------------------------------------------

# previous_tag <gh release list json> <current tag>: the newest published
# release with the release-tag shape, the current tag and the drafts
# excluded; nothing when there is none.
previous_tag() {
    local releases_json=$1
    local current_tag=$2

    jq -r --arg shape "$TAG_SHAPE" --arg current "$current_tag" '
        [.[] | select(.tagName != $current and (.tagName | test($shape)) and .isDraft == false)]
        | sort_by(.publishedAt) | last | .tagName // empty' <<< "$releases_json"
}

# previous_digest <image> <tag>: the digest of that image in the previous
# release. A flavour the previous release lacked prints nothing and succeeds,
# so the notes can state it; any other error fails, because a transport
# problem must never read as "first release of this image".
previous_digest() {
    local image=$1
    local tag=$2
    local reference="docker://${REGISTRY}/${image}:${tag}"
    local error_file=$WORK_DIR/prev-inspect.err
    local inspected digest

    if ! inspected=$(skopeo inspect --retry-times 3 --no-tags "$reference" 2> "$error_file"); then
        if absent_error "$(cat "$error_file")"; then
            return 0
        fi

        print_error "cannot inspect the previous release ${image}:${tag}:" \
            "$(tr '\n' ' ' < "$error_file")"
        return 1
    fi

    digest=$(jq -r .Digest <<< "$inspected")

    if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        print_error "no digest for ${image}:${tag}: '$digest'"
        return 1
    fi

    echo "$digest"
}

# --- SBOMs and package diffs --------------------------------------------------

# fetch_sbom <image> <digest> <out json>: the SBOM attached to that image as
# an OCI referrer. Status 2 when the image carries no SBOM referrer, a case
# the notes state; 1 when oras could not tell, which is never taken for an
# absence.
fetch_sbom() {
    local image=$1
    local digest=$2
    local out=$3
    local reference="${REGISTRY}/${image}@${digest}"
    local error_file=$WORK_DIR/oras.err
    local referrers sbom_digest pull_dir error

    if ! referrers=$(oras discover --format json "$reference" 2> "$error_file"); then
        error=$(< "$error_file")
        print_error "oras discover failed on $reference: ${error:-no output from oras}"
        return 1
    fi

    sbom_digest=$(jq -r --arg type "$SBOM_TYPE" \
        '.referrers[]? | select(.artifactType == $type) | .digest' <<< "$referrers" \
        | head -n1 || true)

    if [ -z "$sbom_digest" ]; then
        print_error "no SBOM referrer on $reference"
        return 2
    fi

    pull_dir=$(mktemp -d -p "$WORK_DIR")

    if ! oras pull --output "$pull_dir" "${REGISTRY}/${image}@${sbom_digest}" > /dev/null \
        2> "$error_file"; then
        error=$(< "$error_file")
        print_error "oras pull of the SBOM $sbom_digest of $reference failed:" \
            "${error:-no output from oras}"
        return 1
    fi

    find "$pull_dir" -name '*.json' -exec mv {} "$out" \; -quit

    if [ ! -s "$out" ]; then
        print_error "SBOM referrer $sbom_digest of $reference pulled no json file"
        return 1
    fi
}

# fetch_current_sbom <image> <digest> <out json>: the SBOM of an image of
# this release. A failure stops the run: a release without an SBOM is a
# build defect, not a gap to state.
fetch_current_sbom() {
    local image=$1
    local digest=$2
    local out=$3

    if ! fetch_sbom "$image" "$digest" "$out"; then
        exit_with_error "the SBOM of the current ${image} could not be read: see the error above"
    fi
}

# sbom_packages <sbom json> <out tsv>: SBOM_ROW for every RPM of a syft SBOM,
# one line per first field, sorted; status 1 when it is not JSON or lists no RPM.
sbom_packages() {
    local sbom=$1
    local out=$2

    if ! jq -r "$SBOM_ROW" "$sbom" \
        2> /dev/null | sort -u -t $'\t' -k1,1 > "$out"; then
        print_error "$sbom is not JSON"
        return 1
    fi

    if [ ! -s "$out" ]; then
        print_error "$sbom lists no RPM"
        return 1
    fi
}

# package_diff <previous tsv> <current tsv>: the Markdown bullets of the
# packages added, changed and removed between two sbom_packages outputs;
# nothing when they are equal.
package_diff() {
    local previous=$1
    local current=$2

    join -t $'\t' -a1 -a2 -e MISSING -o '0,1.2,2.2' "$previous" "$current" | awk -F'\t' '
        $2 == "MISSING" { added = added "- **" $1 "** " $3 " (added)\n"; next }
        $3 == "MISSING" { removed = removed "- **" $1 "** " $2 " (removed)\n"; next }
        $2 != $3 { changed = changed "- **" $1 "** " $2 " → " $3 "\n" }
        END { printf "%s%s%s", added, changed, removed }'
}

# --- release: what the run resolved -------------------------------------------

# parse_arguments <release arguments>...: RELEASE_TAG, NOTES_FILE and
# ENV_FILES from the command line, one env file per flavour required.
parse_arguments() {
    local expected_count

    ENV_FILES=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --release-tag)
                require_option_value "$1" "${2:-}"
                RELEASE_TAG=$2
                shift 2
                ;;
            --out)
                require_option_value "$1" "${2:-}"
                NOTES_FILE=$2
                shift 2
                ;;
            -*)
                exit_with_error "unknown option '$1'"
                ;;
            *)
                ENV_FILES+=("$1")
                shift
                ;;
        esac
    done

    expected_count=$(wc -w <<< "$PACKAGES")

    if [ "${#ENV_FILES[@]}" -ne "$expected_count" ]; then
        exit_with_error "expected $expected_count env files (one per flavour)," \
            "got ${#ENV_FILES[@]}"
    fi
}

# find_previous_tag: PREVIOUS_TAG from the published releases, empty for a
# first release.
find_previous_tag() {
    local error_file=$WORK_DIR/gh.err
    local releases_json error

    if ! releases_json=$(gh release list --repo "$REPO" --limit 500 \
        --json tagName,publishedAt,isDraft 2> "$error_file"); then
        error=$(< "$error_file")
        error=${error//$'\n'/ }
        exit_with_error "gh release list failed: ${error:-no output from gh}"
    fi

    PREVIOUS_TAG=$(previous_tag "$releases_json" "$RELEASE_TAG")
}

# read_flavours: the image and the base of every env file, the kernel of
# each base from its labels, and BASE_VERSION from the first base.
read_flavours() {
    local file base_labels

    for file in "${ENV_FILES[@]}"; do
        if ! read_env "$file"; then
            exit 1
        fi

        if ! base_labels=$(inspect_labels "${base_name}@${base_digest}"); then
            exit_with_error "cannot inspect ${base_name}@${base_digest}"
        fi

        IMAGE_NAMES+=("$image_name")
        IMAGE_DIGESTS+=("$digest")
        BASE_NAMES+=("$base_name")
        BASE_DIGESTS+=("$base_digest")
        KERNELS+=("$(label_of "$base_labels" ostree.linux unknown)")

        if [ -z "$BASE_VERSION" ]; then
            BASE_VERSION=$(label_of "$base_labels" org.opencontainers.image.version "")
        fi
    done
}

# find_previous_revision: PREVIOUS_REVISION from the labels of the first
# flavour the previous release carried; a previous release carrying none of
# the flavours fails. Nothing to do for a first release.
find_previous_revision() {
    local i digest_in_previous previous_labels
    local previous_reference=""

    if [ -z "$PREVIOUS_TAG" ]; then
        return 0
    fi

    for i in "${!IMAGE_NAMES[@]}"; do
        if ! digest_in_previous=$(previous_digest "${IMAGE_NAMES[$i]}" "$PREVIOUS_TAG"); then
            exit 1
        fi

        if [ -n "$digest_in_previous" ]; then
            previous_reference="${REGISTRY}/${IMAGE_NAMES[$i]}@${digest_in_previous}"
            break
        fi
    done

    if [ -z "$previous_reference" ]; then
        exit_with_error "the previous release ${PREVIOUS_TAG} carries none of: ${IMAGE_NAMES[*]}"
    fi

    if ! previous_labels=$(inspect_labels "$previous_reference"); then
        exit_with_error "cannot inspect $previous_reference"
    fi

    PREVIOUS_REVISION=$(label_of "$previous_labels" org.opencontainers.image.revision "")
}

# --- release: the notes -------------------------------------------------------
#
# Each function prints one section of the notes on stdout; `release` sends
# them to NOTES_FILE together. The Markdown keeps its own line breaks: a `\`
# at the end of a heredoc line joins it with the next one.

write_header() {
    local previous_line="First release of this tree."

    if [ -n "$PREVIOUS_TAG" ]; then
        previous_line="Previous release: [\`${PREVIOUS_TAG}\`]"
        previous_line+="(https://github.com/${REPO}/releases/tag/${PREVIOUS_TAG})."
    fi

    cat << EOF
Release \`${RELEASE_TAG}\` of bazzite-mx, built from Bazzite \`${BASE_VERSION}\` (\`stable\`).
${previous_line}

EOF
}

write_images() {
    local i
    local base_list=""

    cat << 'EOF'
## Images

| Image | Kernel | Digest |
|---|---|---|
EOF
    for i in "${!IMAGE_NAMES[@]}"; do
        printf '| `%s/%s:%s` | `%s` | `%s` |\n' "$REGISTRY" "${IMAGE_NAMES[$i]}" "$RELEASE_TAG" \
            "${KERNELS[$i]}" "${IMAGE_DIGESTS[$i]}"
    done

    for i in "${!BASE_NAMES[@]}"; do
        base_list+="${base_list:+, }\`${BASE_NAMES[$i]}@${BASE_DIGESTS[$i]}\`"
    done

    cat << EOF

Base images: ${base_list}.

EOF
}

# write_packages: one section per flavour with its package diff since the
# previous release; one stderr line when no flavour could be compared.
write_packages() {
    local i
    local compared=no

    echo "## Packages"
    echo

    if [ -z "$PREVIOUS_TAG" ]; then
        echo "_No previous release to compare with._"
        echo
        return 0
    fi

    for i in "${!IMAGE_NAMES[@]}"; do
        if write_package_section "$i"; then
            compared=yes
        fi
    done

    if [ "$compared" = no ]; then
        echo "changelog: no package diff for ${RELEASE_TAG}: ${PACKAGE_DIFF_GAPS}" >&2
    fi
}

# write_package_section <index>: the packages of one flavour compared with
# the previous release. Status 0 when a diff was written; 1 when the section
# states a gap instead, the previous release lacking the flavour or carrying
# no readable SBOM, the gap appended to PACKAGE_DIFF_GAPS. A transport error
# on either SBOM stops the run, never stated as a gap.
write_package_section() {
    local i=$1
    local image=${IMAGE_NAMES[$i]}
    local current_sbom=$WORK_DIR/curr-$i.json
    local current_tsv=$WORK_DIR/curr-$i.tsv
    local package_count digest_in_previous

    fetch_current_sbom "$image" "${IMAGE_DIGESTS[$i]}" "$current_sbom"

    if ! sbom_packages "$current_sbom" "$current_tsv"; then
        exit 1
    fi

    package_count=$(wc -l < "$current_tsv")

    if ! digest_in_previous=$(previous_digest "$image" "$PREVIOUS_TAG"); then
        exit 1
    fi

    if [ -z "$digest_in_previous" ]; then
        echo "### ${image}: ${package_count} packages"
        echo
        echo "_First release of this image: \`${PREVIOUS_TAG}\` did not carry it._"
        echo
        PACKAGE_DIFF_GAPS+="${PACKAGE_DIFF_GAPS:+, }${image} not in ${PREVIOUS_TAG}"
        return 1
    fi

    write_package_diff "$i" "$package_count" "$digest_in_previous"
}

# write_package_diff <index> <package count> <digest in the previous release>:
# the diff of one flavour against its previous image's SBOM, or the gap when
# that image carries no SBOM (status 1). An SBOM oras could not read stops
# the run.
write_package_diff() {
    local i=$1
    local package_count=$2
    local digest_in_previous=$3
    local image=${IMAGE_NAMES[$i]}
    local current_tsv=$WORK_DIR/curr-$i.tsv
    local previous_sbom=$WORK_DIR/prev-$i.json
    local previous_tsv=$WORK_DIR/prev-$i.tsv
    local error_file=$WORK_DIR/prev-sbom.err
    local status diff

    if fetch_sbom "$image" "$digest_in_previous" "$previous_sbom" 2> "$error_file"; then
        status=0
    else
        status=$?
    fi

    if [ "$status" -eq 1 ]; then
        exit_with_error "the SBOM of the previous ${image} (${PREVIOUS_TAG}) could not be read:" \
            "$(cat "$error_file")"
    fi

    if [ "$status" -eq 0 ] && sbom_packages "$previous_sbom" "$previous_tsv" 2> /dev/null; then
        diff=$(package_diff "$previous_tsv" "$current_tsv")
        echo "### ${image}: ${package_count} packages, since \`${PREVIOUS_TAG}\`"
        echo

        if [ -n "$diff" ]; then
            echo "$diff"
        else
            echo "_No package changed._"
        fi

        echo
        return 0
    fi

    echo "### ${image}: ${package_count} packages"
    echo
    echo "_No package diff: the previous release \`${PREVIOUS_TAG}\` carries no SBOM._"
    echo
    PACKAGE_DIFF_GAPS+="${PACKAGE_DIFF_GAPS:+, }${image}:${PREVIOUS_TAG} without SBOM"
    return 1
}

# write_commits: the commits since the previous release's revision. A first
# release, and a revision missing from this history (a rewritten one), list
# every commit of this tree and say so. A release cut from the previous
# release's own commit, which every weekly and watcher dispatch is when the
# base alone moved, states that no commit landed.
write_commits() {
    local log_format='- `%h` %s'
    local commits

    echo "## Commits"
    echo

    if [ -z "$PREVIOUS_REVISION" ]; then
        echo "_First release: every commit of this tree follows._"
        echo
        git log --no-merges --pretty="$log_format" HEAD
    elif git cat-file -e "${PREVIOUS_REVISION}^{commit}" 2> /dev/null; then
        commits=$(git log --no-merges --pretty="$log_format" "${PREVIOUS_REVISION}..HEAD")

        if [ -n "$commits" ]; then
            echo "$commits"
        else
            echo "_No commit landed since \`${PREVIOUS_TAG}\`:" \
                "this release rebuilds the same tree._"
        fi
    else
        echo "_Previous revision \`${PREVIOUS_REVISION:0:7}\` is not in this history:" \
            "every commit of this tree follows._"
        echo
        git log --no-merges --pretty="$log_format" HEAD
    fi

    echo
}

write_switch_notes() {
    local repo_url="https://github.com/${REPO}"

    cat << EOF
## Switch a host

A stock Bazzite host carries no trust for \`${REGISTRY}\`: the first rebase goes \
through the unsigned transport and the recipe in the image moves it to the signed one \
([docs/migration.md](${repo_url}/blob/main/docs/migration.md)).

\`\`\`bash
sudo rpm-ostree rebase ostree-unverified-registry:${REGISTRY}/<image>:stable
systemctl reboot
ujust migrate apply
systemctl reboot
ujust verify-host
\`\`\`

A migrated host follows \`:stable\`; to pin this release instead, keeping its image \
(\`ujust migrate apply\` alone goes back to \`:stable\`):

\`\`\`bash
ujust migrate apply ${RELEASE_TAG}
\`\`\`

\`<image>\` is \`bazzite-mx\` (AMD, Intel, or an NVIDIA GPU older than Maxwell), \
\`bazzite-mx-nvidia-open\` (NVIDIA Turing and newer, open kernel modules) or \
\`bazzite-mx-nvidia\` (NVIDIA Maxwell, Pascal and Volta, closed driver). \
Every image is signed with the repository's \
[\`cosign.pub\`](${repo_url}/blob/main/cosign.pub) and its build is attested \
(\`gh attestation verify oci://${REGISTRY}/<image>@<digest> --repo ${REPO}\`). \
\`gh attestation verify\` wants a GitHub login first (\`gh auth login\`, or \`GH_TOKEN\` in the \
environment), public repository or not.

Dated tags stay on GHCR for 90 days (the 7 newest are kept beyond that); \
this release page outlives its tag.
EOF
}

# release <arguments>...: the notes into --out and the title on stdout.
release() {
    parse_arguments "$@"
    find_previous_tag
    read_flavours
    find_previous_revision

    {
        write_header
        write_images
        write_packages
        write_commits
        write_switch_notes
    } > "$NOTES_FILE"

    echo "${RELEASE_TAG}: Stable (Bazzite ${BASE_VERSION})"
}

# --- self-test ----------------------------------------------------------------

# self_test_previous_tag: the newest stable release picked, the current tag,
# a testing tag and a draft skipped, an empty list giving no tag.
self_test_previous_tag() {
    local releases='[
        {"tagName":"44.20260902","publishedAt":"2026-09-02T08:01:52Z","isDraft":false},
        {"tagName":"testing-44.20260902","publishedAt":"2026-09-02T08:01:53Z","isDraft":false},
        {"tagName":"44.20260901","publishedAt":"2026-09-01T08:00:00Z","isDraft":false},
        {"tagName":"44.20260910","publishedAt":"2026-09-10T08:00:00Z","isDraft":true},
        {"tagName":"44.20260903","publishedAt":"2026-09-03T08:00:00Z","isDraft":false}]'

    if [ "$(previous_tag "$releases" 44.20260903)" != 44.20260902 ]; then
        fail_self_test "previous tag not the newest stable release"
    fi

    if [ "$(previous_tag "$releases" 44.20260904)" != 44.20260903 ]; then
        fail_self_test "current tag not excluded"
    fi

    if [ -n "$(previous_tag '[]' 44.20260903)" ]; then
        fail_self_test "empty release list gave a tag"
    fi
}

# self_test_write_sboms <dir>: prev.json and curr.json, syft-shaped, with one
# package added, one changed and listed twice as a multilib package's two
# arches are, one removed, one unchanged, one non-RPM and one gpg-pubkey of
# two replaced.
self_test_write_sboms() {
    local dir=$1

    cat > "$dir/prev.json" << 'EOF'
{"artifacts":[{"type":"rpm","name":"kernel","version":"7.2.1-ogc4.1.fc44"},
{"type":"rpm","name":"kernel","version":"7.2.1-ogc4.1.fc44"},
{"type":"rpm","name":"old","version":"1-1.fc44"},
{"type":"rpm","name":"same","version":"2-1.fc44"},
{"type":"rpm","name":"gpg-pubkey","version":"aaaa-1"},
{"type":"rpm","name":"gpg-pubkey","version":"bbbb-1"},
{"type":"python","name":"pip","version":"25.0"}]}
EOF
    cat > "$dir/curr.json" << 'EOF'
{"artifacts":[{"type":"rpm","name":"kernel","version":"7.2.2-ogc1.fc44"},
{"type":"rpm","name":"kernel","version":"7.2.2-ogc1.fc44"},
{"type":"rpm","name":"new","version":"3-1.fc44"},
{"type":"rpm","name":"same","version":"2-1.fc44"},
{"type":"rpm","name":"gpg-pubkey","version":"aaaa-1"},
{"type":"rpm","name":"gpg-pubkey","version":"cccc-1"},
{"type":"python","name":"pip","version":"26.0"}]}
EOF
}

# self_test_package_diff <dir>: sbom_packages and package_diff on fixture
# SBOMs, and the malformed SBOMs sbom_packages refuses.
self_test_package_diff() {
    local dir=$1
    local diff output

    self_test_write_sboms "$dir"

    if ! sbom_packages "$dir/prev.json" "$dir/prev.tsv"; then
        fail_self_test "SBOM not parsed"
    fi

    if ! sbom_packages "$dir/curr.json" "$dir/curr.tsv"; then
        fail_self_test "SBOM not parsed"
    fi

    if [ "$(wc -l < "$dir/curr.tsv")" -ne 5 ]; then
        fail_self_test "expected 5 RPMs, got $(wc -l < "$dir/curr.tsv")"
    fi

    diff=$(package_diff "$dir/prev.tsv" "$dir/curr.tsv")

    if ! grep -qx -- '- \*\*new\*\* 3-1.fc44 (added)' <<< "$diff"; then
        fail_self_test "added package missing: $diff"
    fi

    if ! grep -qx -- '- \*\*kernel\*\* 7.2.1-ogc4.1.fc44 → 7.2.2-ogc1.fc44' <<< "$diff"; then
        fail_self_test "changed package missing"
    fi

    if ! grep -qx -- '- \*\*old\*\* 1-1.fc44 (removed)' <<< "$diff"; then
        fail_self_test "removed package missing"
    fi

    if ! grep -qx -- '- \*\*gpg-pubkey cccc-1\*\* cccc-1 (added)' <<< "$diff" \
        || ! grep -qx -- '- \*\*gpg-pubkey bbbb-1\*\* bbbb-1 (removed)' <<< "$diff"; then
        fail_self_test "a replaced gpg-pubkey missing: $diff"
    fi

    if grep -q 'same' <<< "$diff"; then
        fail_self_test "unchanged package listed"
    fi

    if [ -n "$(package_diff "$dir/curr.tsv" "$dir/curr.tsv")" ]; then
        fail_self_test "identical SBOMs gave a diff"
    fi

    echo '{"artifacts":[{"type":"python","name":"pip","version":"26.0"}]}' > "$dir/norpm.json"
    REFUSED=$((REFUSED + 1))

    if sbom_packages "$dir/norpm.json" "$dir/norpm.tsv" 2> /dev/null; then
        fail_self_test "SBOM without RPMs accepted"
    fi

    # Known-bad: jq's own line, then `lists no RPM` for the wrong reason.
    echo 'not json' > "$dir/notjson.json"
    REFUSED=$((REFUSED + 1))

    if output=$(sbom_packages "$dir/notjson.json" "$dir/notjson.tsv" 2>&1); then
        fail_self_test "SBOM that is not JSON accepted"
    fi

    if ! grep -q "^changelog: $dir/notjson.json is not JSON$" <<< "$output" \
        || grep -q '^jq:' <<< "$output"; then
        fail_self_test "SBOM that is not JSON not named: $(head -n1 <<< "$output")"
    fi
}

# self_test_release_arguments <dir>: two env files refused by release for
# three flavours, the count taken from PACKAGES. The env file's own shape is
# lib.sh's read_env, proven there.
self_test_release_arguments() {
    local dir=$1
    local expected_count output

    expected_count=$(wc -w <<< "$PACKAGES")
    REFUSED=$((REFUSED + 1))

    if output=$(release --release-tag 44.20260903 --out "$dir/notes.md" \
        "$dir/bad.env" "$dir/bad.env" 2>&1); then
        fail_self_test "two env files accepted for $expected_count flavours"
    fi

    if ! grep -q "expected $expected_count env files" <<< "$output"; then
        fail_self_test "the env-file count is not PACKAGES': $output"
    fi
}

# self_test_write_skopeo_shim <dir>: a skopeo on PATH answering for the
# previous release's images by SKOPEO_SHIM: a digest, a digest after a retry
# noted on stderr, an absent image, or an authentication error.
self_test_write_skopeo_shim() {
    local dir=$1

    cat > "$dir/bin/skopeo" << 'EOF'
#!/usr/bin/env bash
if [[ "${!#}" != docker://ghcr.io/matrixdj96/bazzite-mx*:44.20260903 ]]; then
    echo "shim: unexpected reference ${!#}" >&2
    exit 3
fi

case "$SKOPEO_SHIM" in
    ok)
        printf '{"Digest":"sha256:%064d"}\n' 7
        ;;
    absent)
        echo 'level=fatal msg="reading manifest t in ghcr.io/x/y: manifest unknown"' >&2
        exit 1
        ;;
    retry)
        echo 'WARN retrying (1/3)' >&2
        printf '{"Digest":"sha256:%064d","Labels":{"ostree.linux":"%s"}}\n' 7 \
            7.2.1-ogc4.1.fc44.x86_64
        ;;
    *)
        echo 'unauthorized: authentication required' >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$dir/bin/skopeo"
}

# self_test_previous_digest <dir>: a readable previous image gives its
# digest, an absent one nothing, an authentication error fails instead of
# reading as absent.
self_test_previous_digest() {
    local dir=$1
    local digest

    self_test_write_skopeo_shim "$dir"

    if ! digest=$(PATH="$dir/bin:$PATH" SKOPEO_SHIM=ok previous_digest bazzite-mx \
        44.20260903); then
        fail_self_test "a readable previous image refused"
    fi

    if [ "$digest" != "sha256:$(printf '%064d' 7)" ]; then
        fail_self_test "previous digest not read: '$digest'"
    fi

    if ! digest=$(PATH="$dir/bin:$PATH" SKOPEO_SHIM=absent previous_digest \
        bazzite-mx-nvidia 44.20260903); then
        fail_self_test "a flavour absent from the previous release failed instead of being stated"
    fi

    if [ -n "$digest" ]; then
        fail_self_test "an absent previous image gave a digest: '$digest'"
    fi

    REFUSED=$((REFUSED + 1))

    if PATH="$dir/bin:$PATH" SKOPEO_SHIM=auth previous_digest bazzite-mx 44.20260903 \
        > /dev/null 2>&1; then
        fail_self_test "a transport error on the previous image taken for an absent one"
    fi
}

# self_test_inspect_retry_note <dir>: a skopeo that retried and then succeeded
# gives the labels alone, its note on neither channel.
self_test_inspect_retry_note() {
    local dir=$1
    local error_file=$dir/retry.err
    local labels

    self_test_write_skopeo_shim "$dir"

    if ! labels=$(PATH="$dir/bin:$PATH" SKOPEO_SHIM=retry \
        inspect_labels "$REGISTRY/bazzite-mx:44.20260903" 2> "$error_file"); then
        fail_self_test "a skopeo that retried and succeeded was read as a failure"
    fi

    if [ "$labels" != '{"ostree.linux":"7.2.1-ogc4.1.fc44.x86_64"}' ]; then
        fail_self_test "the retry note reached the labels: ${labels//$'\n'/ }"
    fi

    if [ -s "$error_file" ]; then
        fail_self_test "the retry note reached stderr: $(< "$error_file")"
    fi
}

# self_test_write_oras_shim <dir>: an oras on PATH answering by ORAS_SHIM
# with an image without referrers or a transport error.
self_test_write_oras_shim() {
    local dir=$1

    cat > "$dir/bin/oras" << 'EOF'
#!/usr/bin/env bash
case "$ORAS_SHIM" in
    none)
        echo '{"referrers":[]}'
        ;;
    *)
        echo 'Error: failed to resolve ghcr.io: dial tcp: lookup ghcr.io: no such host' >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$dir/bin/oras"
}

# self_test_fetch_sbom <dir>: an image without an SBOM referrer gives status
# 2, stated in the notes; a transport error gives status 1, never taken for
# a missing SBOM, and on the previous release's SBOM stops the notes.
self_test_fetch_sbom() {
    local dir=$1
    local digest status output

    self_test_write_oras_shim "$dir"
    digest="sha256:$(printf '%064d' 7)"

    if PATH="$dir/bin:$PATH" ORAS_SHIM=none fetch_sbom bazzite-mx "$digest" \
        "$dir/none.json" 2> /dev/null; then
        status=0
    else
        status=$?
    fi

    if [ "$status" -ne 2 ]; then
        fail_self_test "an image without an SBOM referrer exited $status, not 2"
    fi

    REFUSED=$((REFUSED + 1))

    if output=$(PATH="$dir/bin:$PATH" ORAS_SHIM=down fetch_sbom bazzite-mx "$digest" \
        "$dir/down.json" 2>&1); then
        status=0
    else
        status=$?
    fi

    if [ "$status" -ne 1 ]; then
        fail_self_test "a transport error on oras discover exited $status, not 1" \
            "(taken for no SBOM)"
    fi

    # Known-bad: oras's own line reached stderr, the script's carried no reason.
    if [ "$(grep -c '' <<< "$output")" -ne 1 ] \
        || ! grep -q '^changelog: oras discover failed on .*: Error: failed to resolve' \
            <<< "$output"; then
        fail_self_test "a transport error not folded into one line: ${output//$'\n'/ }"
    fi

    REFUSED=$((REFUSED + 1))

    if output=$(
        IMAGE_NAMES=(bazzite-mx)
        PREVIOUS_TAG=44.20260902
        PATH="$dir/bin:$PATH" ORAS_SHIM=down write_package_diff 0 1 "$digest" 2> /dev/null
    ) || grep -q 'carries no SBOM' <<< "$output"; then
        fail_self_test "a transport error on the previous SBOM stated as a gap"
    fi
}

self_test() {
    local dir

    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    mkdir -p "$dir/bin"

    self_test_previous_tag
    self_test_package_diff "$dir"
    self_test_release_arguments "$dir"
    self_test_previous_digest "$dir"
    self_test_inspect_retry_note "$dir"
    self_test_fetch_sbom "$dir"

    echo "self-test ok: previous tag picked 3 ways, 1 SBOM diff right," \
        "previous digest classified 3 ways, a retried inspect kept clean," \
        "SBOM absence told from a transport error, $REFUSED bad inputs refused"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    release)
        shift
        release "$@"
        ;;
    *)
        exit_with_error "usage: changelog.sh release --release-tag <tag> --out <file>" \
            "<env-file>... | --self-test"
        ;;
esac
