#!/usr/bin/env bash
# Writes the notes and the title of a GitHub Release from what the release run
# resolved, in the shape of ublue-os/bazzite's .github/workflows/changelog.py.
#
# Sections: the release line, the previous release, the Bazzite release it
# builds on, the major packages, the commits since the previous release, the
# packages changed on every flavour and on the NVIDIA ones, and how to rebase,
# through `ujust migrate` since bazzite-rollback-helper rebases to
# ghcr.io/ublue-os. The previous release is the newest in `gh release list`, not
# a manifest's RepoTags, which an orphan tag would hijack.
#
# The build job writes packages-<image>.json from its SBOM, the release attaches
# their union as packages.json, and the next release reads that asset instead of
# pulling the previous SBOMs.
#
# Usage: changelog.sh release --release-tag <tag> --out <file> [--handwritten <text>]
#          [--packages-dir <dir>] [--packages-out <file>] <env-file>...
#          --release-tag <tag>   the tag being released, <fedora>.<yyyymmdd>[.N]
#          --out <file>          where the notes are written
#          --handwritten <text>  the notes' first paragraph in place of the
#                                generated line; empty keeps that line
#          --packages-dir <dir>  where the build jobs' packages-<image>.json are
#          --packages-out <file> where this release's packages.json is written
#          <env-file>...         one per flavour, from the build job: image_name,
#                                digest, base_name, base_digest
#        changelog.sh packages --sbom <file> --image <name> --version <tag>
#          --out <file>
#        changelog.sh --self-test
# Output: release: the title on stdout, `<tag>: Stable (Bazzite <version>)`; the
#   notes in the --out file; `changelog: no package diff for <tag>: …` on stderr
#   when no flavour could be compared with the previous release, and the reason
#   on stderr when the previous release's packages.json is not used. packages: the
#   file {image, version, packages} at --out.
# Exit status: 0 notes or file written; 1 on a bad argument, an image that
#   cannot be inspected, an SBOM that cannot be read, a release list gh cannot
#   read or a previous release carrying none of the flavours. A transport error
#   on the release list, an image or an SBOM is never taken for an absence.
# Needs skopeo, oras, jq, gh (GH_TOKEN) and git with the history: the release
#   workflow fetches 500 commits so the previous release's revision is reached.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SBOM_TYPE=application/vnd.spdx+json
UPSTREAM_REPO=ublue-os/bazzite

# One version per RPM name: the first listed, unless a later one carries an
# epoch it lacks.
SBOM_PACKAGES='reduce (.artifacts[] | select(.type == "rpm" and (.name // "") != ""
        and (.version // "") != "")) as $a ({};
    if .[$a.name] == null
        or (($a.version | contains(":")) and (.[$a.name] | contains(":") | not))
    then .[$a.name] = $a.version else . end)'

# The Major packages rows, label and RPM; a row whose RPM no flavour carries is
# left out.
MAJOR_PACKAGES='[["Kernel", "kernel-core"], ["Kernel (Nvidia LTS)", "kernel-core-lts"],
    ["Firmware", "atheros-firmware"], ["Mesa", "mesa-filesystem"],
    ["Gamescope", "terra-gamescope"], ["MangoHUD", "terra-mangohud"], ["KDE", "plasma-desktop"],
    ["Nvidia Open", "nvidia-kmod-common"], ["Nvidia LTS", "nvidia-kmod-common-lts"],
    ["Docker", "docker-ce"], ["Podman", "podman"], ["QEMU", "qemu-kvm"], ["libvirt", "libvirt"],
    ["VS Code", "code"], ["Sunshine", "Sunshine"]]'

# Left out of the tables, and so is every package sharing the current version of
# one of them.
HIDDEN_VERSIONS='["kernel", "kernel-core", "kernel-lts", "kernel-core-lts", "mesa-filesystem",
    "terra-gamescope", "plasma-desktop", "atheros-firmware", "nvidia-kmod-common",
    "nvidia-kmod-common-lts"]'

# Over {images: [{name, curr, prev}]}; $mode major prints the Major packages
# table, changes the tables. prev is null for a flavour not compared, whose
# versions reach only the Major values, never an arrow or a table. A name whose
# versions all went to -lts keys is skipped where changelog.py raises KeyError.
# The images go in name order (changelog.py's IMAGES order): the last one
# carrying a package gives its version.
PACKAGE_TABLES='
def norm: sub("^[0-9]+:"; "") | gsub("\\.fc[0-9]{2}"; "");
def lts: test("nvidia") and (test("nvidia-open") | not);
def key($lts): if $lts and (test("nvidia") or test("^kernel(-|$)")) then . + "-lts" else . end;
def versions($side): reduce .[] as $i ({};
    . + (($i[$side] // {}) | with_entries(.key |= key($i.name | lts) | .value |= norm)));
def shared: reduce .[1:][] as $n (.[0]; . - (. - $n));
def changes($pkgs; $prev; $curr; $hidden):
    reduce $pkgs[] as $p ({seen: [$hidden[] as $h | $curr[$h] | select(. != null)],
            added: [], changed: [], removed: []};
        if ($hidden | index($p)) or ($p | endswith("-lts"))
            or ($prev[$p] == null and $curr[$p] == null)
            or ($curr[$p] != null and (.seen | index($curr[$p])))
            or ($prev[$p] != null and (.seen | index($prev[$p]))) then .
        else
            (if $prev[$p] == null then .added += [$p]
             elif $curr[$p] == null then .removed += [$p]
             elif $prev[$p] != $curr[$p] then .changed += [$p]
             else . end)
            | .seen += [$curr[$p], $prev[$p] | select(. != null)]
        end)
    | [(.added[] as $p | "| ✨ | \($p) | | \($curr[$p]) |"),
       (.changed[] as $p | "| 🔄 | \($p) | \($prev[$p]) | \($curr[$p]) |"),
       (.removed[] as $p | "| ❌ | \($p) | \($prev[$p]) | |")];
def table($title; $rows):
    if ($rows | length) > 0 then
        "### \($title)\n| | Name | Previous | New |\n| --- | --- | --- | --- |\n"
        + ($rows | join("\n")) + "\n"
    else empty end;
(.images | sort_by(.name)) as $images
| [$images[] | select(.prev != null)] as $compared
| ($compared | versions("prev")) as $prev | ($compared | versions("curr")) as $curr
| if $mode == "major" then
    "### Major packages\n| Name | Version |\n| --- | --- |\n"
    + ([$major[] as [$label, $p] | ($images | versions("curr"))[$p] | select(. != null)
        | "| **\($label)** | "
          + (if $prev[$p] == null or $curr[$p] == null or $prev[$p] == $curr[$p] then .
             else "\($prev[$p]) ➡️ \($curr[$p])" end)
          + " |"] | join("\n")) + "\n"
  else
    [$compared[] | (.prev + .curr) | keys] as $all
    | [$compared[] | select(.name | test("nvidia")) | (.prev + .curr) | keys] as $nvidia
    | (if ($all | length) > 0 then $all | shared else [] end) as $common
    | table("All Images"; changes($common; $prev; $curr; $hidden)),
      (if ($nvidia | length) > 0 then
          table("Nvidia Images"; changes(($nvidia | shared) - $common; $prev; $curr; $hidden))
       else empty end)
  end'

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# --- the release being described ----------------------------------------------
#
# Set by parse_arguments, find_previous_tag, read_flavours and
# find_previous_revision, in that order. The arrays hold one entry per env file,
# in the order the files were given.

RELEASE_TAG=""
NOTES_FILE=""
HANDWRITTEN=""
PACKAGES_DIR=""
PACKAGES_OUT=""
ENV_FILES=()
BASE_VERSION=""
BASE_VERSIONS=""
PREVIOUS_TAG=""
PREVIOUS_REVISION=""
IMAGE_NAMES=()
IMAGE_DIGESTS=()

# Appended by read_previous_packages, read by write_package_changes.
PACKAGE_DIFF_GAPS=""

# Set by fetch_previous_packages: the previous release's packages.json, empty
# when it has none to read.
PREVIOUS_PACKAGES=""

# --- image labels -------------------------------------------------------------

# inspect_labels <image@digest>: the labels of that image as one JSON object.
inspect_labels() {
    local reference=$1
    local error_file=$WORK_DIR/labels.err
    local manifest error

    if ! manifest=$(skopeo inspect --retry-times 3 --no-tags "docker://$reference" \
        2> "$error_file"); then
        error=$(< "$error_file")
        error=${error//$'\n'/ }
        print_error "skopeo inspect $reference: ${error:-no output from skopeo}"
        return 1
    fi

    jq -c '.Labels' <<< "$manifest"
}

# label_of <labels json> <label>: the label's value, empty when the image does
# not carry it.
label_of() {
    local labels_json=$1
    local label=$2

    jq -r --arg label "$label" '.[$label] // ""' <<< "$labels_json"
}

# --- the previous release -----------------------------------------------------

# previous_tag <gh release list json> <current tag>: the newest published
# release with the release-tag shape, the current tag and the drafts excluded;
# nothing when there is none.
previous_tag() {
    local releases_json=$1
    local current_tag=$2

    jq -r --arg shape "$TAG_SHAPE" --arg current "$current_tag" '
        [.[] | select(.tagName != $current and (.tagName | test($shape)) and .isDraft == false)]
        | sort_by(.publishedAt) | last | .tagName // empty' <<< "$releases_json"
}

# previous_digest <image> <tag>: the digest of that image in the previous
# release. A flavour the previous release lacked prints nothing and succeeds;
# any other error fails, because a transport problem must never read as "first
# release of this image".
previous_digest() {
    local image=$1
    local tag=$2
    local reference="docker://${REGISTRY}/${image}:${tag}"
    local error_file=$WORK_DIR/prev-inspect.err
    local inspected error

    if ! inspected=$(skopeo inspect --retry-times 3 --no-tags "$reference" 2> "$error_file"); then
        error=$(< "$error_file")

        if absent_error "$error"; then
            return 0
        fi

        error=${error//$'\n'/ }
        print_error "cannot inspect the previous release ${image}:${tag}:" \
            "${error:-no output from skopeo}"
        return 1
    fi

    jq -r .Digest <<< "$inspected"
}

# --- SBOMs and package tables -------------------------------------------------

# fetch_sbom <image> <digest> <out json>: the SBOM attached to that image as an
# OCI referrer. Status 2 when the image carries no SBOM referrer; 1 when oras
# could not tell, which is never taken for an absence.
fetch_sbom() {
    local image=$1
    local digest=$2
    local out=$3
    local reference="${REGISTRY}/${image}@${digest}"
    local error_file=$WORK_DIR/oras.err
    local referrers sbom_digest pull_dir error

    if ! referrers=$(oras discover --format json "$reference" 2> "$error_file"); then
        error=$(< "$error_file")
        error=${error//$'\n'/ }
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
        error=${error//$'\n'/ }
        print_error "oras pull of the SBOM $sbom_digest of $reference failed:" \
            "${error:-no output from oras}"
        return 1
    fi

    find "$pull_dir" -name '*.json' -exec mv {} "$out" \; -quit
}

# sbom_packages <sbom json> <out json>: SBOM_PACKAGES of a syft SBOM, one
# {name: version} object; status 1 when it is missing, not JSON, has no
# artifacts or lists no RPM.
sbom_packages() {
    local sbom=$1
    local out=$2

    if ! jq "$SBOM_PACKAGES" "$sbom" > "$out" 2> /dev/null; then
        print_error "$sbom is not a syft SBOM"
        return 1
    fi

    if [ "$(jq length "$out")" -eq 0 ]; then
        print_error "$sbom lists no RPM"
        return 1
    fi
}

# package_file_for <file> <image> <version> <out json>: the packages of a
# packages-<image>.json written for that image and version; fails when the file
# is missing, not JSON or for another image or version.
package_file_for() {
    local file=$1
    local image=$2
    local version=$3
    local out=$4

    jq -e --arg image "$image" --arg version "$version" \
        'select(.image == $image and .version == $version) | .packages' \
        "$file" > "$out" 2> /dev/null
}

# package_tables <images json> <mode>: PACKAGE_TABLES in that mode, major or
# changes.
package_tables() {
    local images=$1
    local mode=$2

    jq -r --arg mode "$mode" --argjson major "$MAJOR_PACKAGES" \
        --argjson hidden "$HIDDEN_VERSIONS" "$PACKAGE_TABLES" "$images"
}

# --- release: what the run resolved -------------------------------------------

# parse_arguments <release arguments>...: RELEASE_TAG, NOTES_FILE, HANDWRITTEN,
# PACKAGES_DIR, PACKAGES_OUT and ENV_FILES from the command line; stops the run
# on an unknown option or one without its value, --handwritten taking an empty
# one.
parse_arguments() {
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
            --handwritten)
                if [ $# -lt 2 ]; then
                    exit_with_error "$1 needs a value"
                fi

                HANDWRITTEN=$2
                shift 2
                ;;
            --packages-dir)
                require_option_value "$1" "${2:-}"
                PACKAGES_DIR=$2
                shift 2
                ;;
            --packages-out)
                require_option_value "$1" "${2:-}"
                PACKAGES_OUT=$2
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
}

# find_previous_tag: PREVIOUS_TAG from the published releases, empty for a first
# release; stops the run when gh cannot list them.
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

# read_flavours: the image and the base of every env file; BASE_VERSIONS the
# distinct versions of the bases, BASE_VERSION the highest. Every base carries
# org.opencontainers.image.version: resolve-base.sh refuses one without it.
# Stops the run on a base it cannot inspect.
read_flavours() {
    local file base_labels
    local versions=()

    for file in "${ENV_FILES[@]}"; do
        read_env "$file"

        if ! base_labels=$(inspect_labels "${base_name}@${base_digest}"); then
            exit_with_error "cannot inspect ${base_name}@${base_digest}"
        fi

        IMAGE_NAMES+=("$image_name")
        IMAGE_DIGESTS+=("$digest")
        versions+=("$(label_of "$base_labels" org.opencontainers.image.version)")
    done

    BASE_VERSIONS=$(printf '%s\n' "${versions[@]}" | sort -Vu || true)
    BASE_VERSION=$(tail -n1 <<< "$BASE_VERSIONS")
}

# find_previous_revision: PREVIOUS_REVISION from the labels of the first flavour
# the previous release carried. Stops the run on a previous release carrying
# none of the flavours, a transport error on a previous image or labels it
# cannot inspect. Nothing to do for a first release.
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

    PREVIOUS_REVISION=$(label_of "$previous_labels" org.opencontainers.image.revision)
}

# read_packages: WORK_DIR/images.json, one {name, curr, prev} per flavour, prev
# null when the flavour cannot be compared with a previous release.
read_packages() {
    local i image

    if [ -n "$PREVIOUS_TAG" ]; then
        fetch_previous_packages
    fi

    for i in "${!IMAGE_NAMES[@]}"; do
        image=${IMAGE_NAMES[$i]}
        read_current_packages "$i"
        echo null > "$WORK_DIR/prev-$i.json"

        if [ -n "$PREVIOUS_TAG" ]; then
            read_previous_packages "$i"
        fi

        jq -n --arg name "$image" --slurpfile curr "$WORK_DIR/curr-$i.json" \
            --slurpfile prev "$WORK_DIR/prev-$i.json" \
            '{name: $name, curr: $curr[0], prev: $prev[0]}' > "$WORK_DIR/image-$i.json"
    done

    jq -s '{images: .}' "$WORK_DIR"/image-*.json > "$WORK_DIR/images.json"
}

# read_current_packages <index>: WORK_DIR/curr-<index>.json from this run's
# packages-<image>.json, or from the image's SBOM when the file is missing or
# describes anything else. An image without either stops the run.
read_current_packages() {
    local i=$1
    local image=${IMAGE_NAMES[$i]}

    if [ -n "$PACKAGES_DIR" ] \
        && package_file_for "$PACKAGES_DIR/packages-$image.json" "$image" "$RELEASE_TAG" \
            "$WORK_DIR/curr-$i.json"; then
        return 0
    fi

    if ! fetch_sbom "$image" "${IMAGE_DIGESTS[$i]}" "$WORK_DIR/curr-$i.sbom" \
        || ! sbom_packages "$WORK_DIR/curr-$i.sbom" "$WORK_DIR/curr-$i.json"; then
        exit 1
    fi
}

# fetch_previous_packages: PREVIOUS_PACKAGES, the packages.json attached to the
# previous release, left empty, the reason on stderr, when gh cannot download
# one or it is for another release.
fetch_previous_packages() {
    local file=$WORK_DIR/previous-packages.json
    local version

    if ! gh release download "$PREVIOUS_TAG" --repo "$REPO" --pattern packages.json \
        --output "$file" > /dev/null; then
        echo "$SCRIPT_NAME: no packages.json on release ${PREVIOUS_TAG}, reading the SBOMs" >&2
        return 0
    fi

    if ! jq -e --arg tag "$PREVIOUS_TAG" \
        '.version == $tag and (.images | type) == "object"' "$file" > /dev/null 2>&1; then
        version=$(jq -r '.version // empty' "$file" 2> /dev/null || true)
        echo "$SCRIPT_NAME: packages.json on release ${PREVIOUS_TAG} is for" \
            "${version:-no release}, reading the SBOMs" >&2
        return 0
    fi

    PREVIOUS_PACKAGES=$file
}

# read_previous_packages <index>: WORK_DIR/prev-<index>.json from the previous
# release's packages.json or, without one, from its image of that flavour; a
# flavour the previous release lacked, or whose image carries no readable SBOM,
# stays null and is appended to PACKAGE_DIFF_GAPS. A transport error on the
# image or its SBOM stops the run.
read_previous_packages() {
    local i=$1
    local image=${IMAGE_NAMES[$i]}
    local previous_sbom=$WORK_DIR/prev-$i.sbom
    local error_file=$WORK_DIR/prev-sbom.err
    local digest_in_previous status

    if [ -n "$PREVIOUS_PACKAGES" ]; then
        jq --arg image "$image" '.images[$image]' "$PREVIOUS_PACKAGES" \
            > "$WORK_DIR/prev-$i.json"

        if [ "$(< "$WORK_DIR/prev-$i.json")" = null ]; then
            PACKAGE_DIFF_GAPS+="${PACKAGE_DIFF_GAPS:+, }${image} not in ${PREVIOUS_TAG}"
        fi

        return 0
    fi

    if ! digest_in_previous=$(previous_digest "$image" "$PREVIOUS_TAG"); then
        exit 1
    fi

    if [ -z "$digest_in_previous" ]; then
        PACKAGE_DIFF_GAPS+="${PACKAGE_DIFF_GAPS:+, }${image} not in ${PREVIOUS_TAG}"
        return 0
    fi

    if fetch_sbom "$image" "$digest_in_previous" "$previous_sbom" 2> "$error_file"; then
        status=0
    else
        status=$?
    fi

    if [ "$status" -eq 1 ]; then
        cat "$error_file" >&2
        exit 1
    fi

    if [ "$status" -eq 0 ] \
        && sbom_packages "$previous_sbom" "$WORK_DIR/prev-$i.json" 2> /dev/null; then
        return 0
    fi

    echo null > "$WORK_DIR/prev-$i.json"
    PACKAGE_DIFF_GAPS+="${PACKAGE_DIFF_GAPS:+, }${image}:${PREVIOUS_TAG} without SBOM"
}

# --- release: the notes -------------------------------------------------------
#
# Each function prints one section of the notes on stdout; `release` sends them
# to NOTES_FILE together.

write_header() {
    local generated="This is an automatically generated changelog for release \`${RELEASE_TAG}\`."

    printf '%s\n' "${HANDWRITTEN:-$generated}"
    echo

    if [ -n "$PREVIOUS_TAG" ]; then
        echo "From previous \`stable\` version \`${PREVIOUS_TAG}\` there have been the following" \
            "changes. **One package per new version shown.**"
        echo
    fi

    echo "Built on Bazzite $(awk -v url="https://github.com/${UPSTREAM_REPO}/releases/tag/" \
        '{ printf "%s[%s](%s%s)", (NR > 1 ? ", " : ""), $0, url, $0 }' <<< "$BASE_VERSIONS")."
    echo
}

write_major_packages() {
    package_tables "$WORK_DIR/images.json" major
}

# write_commits: the commits since the previous release's revision, as a table;
# no section when the release rebuilds the previous one's commit. A first
# release, and a revision missing from this history (a rewritten one), list
# every commit of this tree.
write_commits() {
    local range=HEAD
    local commits

    if [ -n "$PREVIOUS_REVISION" ] \
        && git cat-file -e "${PREVIOUS_REVISION}^{commit}" 2> /dev/null; then
        range="${PREVIOUS_REVISION}..HEAD"
    fi

    git log --no-merges --pretty='%H%x09%h%x09%an%x09%s' "$range" > "$WORK_DIR/commits.tsv"
    commits=$(awk -F'\t' -v url="https://github.com/${REPO}/commit/" '{
        gsub(/\|/, "\\|", $3)
        gsub(/\|/, "\\|", $4)
        printf "| **[%s](%s%s)** | %s | %s |\n", $2, url, $1, $4, $3 }' "$WORK_DIR/commits.tsv")

    if [ -z "$commits" ]; then
        return 0
    fi

    echo "### Commits"
    echo "| Hash | Subject | Author |"
    echo "| --- | --- | --- |"
    echo "$commits"
    echo
}

# write_package_changes: the tables of the packages changed since the previous
# release; one stderr line when no flavour could be compared.
write_package_changes() {
    local tables compared

    if [ -z "$PREVIOUS_TAG" ]; then
        return 0
    fi

    tables=$(package_tables "$WORK_DIR/images.json" changes)

    if [ -n "$tables" ]; then
        echo "$tables"
        echo
    fi

    compared=$(jq 'any(.images[]; .prev != null)' "$WORK_DIR/images.json")

    if [ "$compared" = false ]; then
        echo "changelog: no package diff for ${RELEASE_TAG}: ${PACKAGE_DIFF_GAPS}" >&2
    fi
}

write_rebase() {
    cat << EOF
### How to rebase
For current users, type the following to rebase to this version:
\`\`\`bash
# For this branch (if latest):
ujust migrate stable
# For this specific image:
ujust migrate ${RELEASE_TAG}
\`\`\`
EOF
}

# write_release_packages: this release's packages per image into
# --packages-out, for the next release's notes; nothing without the option.
write_release_packages() {
    if [ -z "$PACKAGES_OUT" ]; then
        return 0
    fi

    jq --arg tag "$RELEASE_TAG" \
        '{version: $tag, images: (.images | map({(.name): .curr}) | add)}' \
        "$WORK_DIR/images.json" > "$PACKAGES_OUT"
}

# release <arguments>...: the notes into --out and the title on stdout.
release() {
    parse_arguments "$@"
    find_previous_tag
    read_flavours
    find_previous_revision
    read_packages
    write_release_packages

    {
        write_header
        write_major_packages
        write_commits
        write_package_changes
        write_rebase
    } > "$NOTES_FILE"

    echo "${RELEASE_TAG}: Stable (Bazzite ${BASE_VERSION})"
}

# --- packages: one image's file -----------------------------------------------

# packages <arguments>...: --out, {image, version, packages}, from the --sbom of
# that --image and --version.
packages() {
    local sbom="" image="" version="" out=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --sbom | --image | --version | --out)
                require_option_value "$1" "${2:-}"
                printf -v "${1#--}" '%s' "$2"
                shift 2
                ;;
            *)
                exit_with_error "unknown argument '$1'"
                ;;
        esac
    done

    if [ -z "$sbom" ] || [ -z "$image" ] || [ -z "$version" ] || [ -z "$out" ]; then
        exit_with_error "packages needs --sbom, --image, --version and --out"
    fi

    if ! sbom_packages "$sbom" "$WORK_DIR/sbom-packages.json"; then
        exit 1
    fi

    jq -n --arg image "$image" --arg version "$version" \
        --slurpfile packages "$WORK_DIR/sbom-packages.json" \
        '{image: $image, version: $version, packages: $packages[0]}' > "$out"
}

# --- self-test ----------------------------------------------------------------

# self_test_previous_tag: the newest stable release picked, the current tag, a
# testing tag and a draft skipped, an empty list giving no tag, a gh that cannot
# list the releases stopping the notes.
self_test_previous_tag() {
    local output
    local releases='[
        {"tagName":"44.20260902","publishedAt":"2026-09-02T08:01:52Z","isDraft":false},
        {"tagName":"testing-44.20260902","publishedAt":"2026-09-02T08:01:53Z","isDraft":false},
        {"tagName":"44.20260901","publishedAt":"2026-09-01T08:00:00Z","isDraft":false},
        {"tagName":"44.20260910","publishedAt":"2026-09-10T08:00:00Z","isDraft":true},
        {"tagName":"44.20260903","publishedAt":"2026-09-03T08:00:00Z","isDraft":false}]'

    if [ "$(previous_tag "$releases" 44.20260903)" != 44.20260902 ]; then
        fail_self_test "current or testing tag not excluded"
    fi

    if [ "$(previous_tag "$releases" 44.20260904)" != 44.20260903 ]; then
        fail_self_test "newest published release not picked, or the draft not skipped"
    fi

    if [ -n "$(previous_tag '[]' 44.20260903)" ]; then
        fail_self_test "empty release list gave a tag"
    fi

    gh() {
        echo 'HTTP 403: API rate limit exceeded' >&2
        return 1
    }
    REFUSED=$((REFUSED + 1))

    if output=$(find_previous_tag 2>&1) \
        || ! grep -q 'gh release list failed: HTTP 403' <<< "$output"; then
        fail_self_test "a gh that cannot list the releases not refused: ${output:-no output}"
    fi

    unset -f gh
}

# self_test_sbom_packages <dir>: one version per RPM name, the epoch-carrying
# one preferred, every gpg-pubkey under one name, non-RPMs and RPMs with an
# empty name or version skipped; and the malformed SBOMs sbom_packages refuses.
self_test_sbom_packages() {
    local dir=$1
    local output expected

    cat > "$dir/sbom.json" << 'EOF'
{"artifacts":[{"type":"rpm","name":"kernel","version":"7.2.1-ogc4.1.fc44"},
{"type":"rpm","name":"kernel","version":"7.2.1-ogc4.1.fc44"},
{"type":"rpm","name":"mesa-filesystem","version":"26.2.4-1.fc44"},
{"type":"rpm","name":"mesa-filesystem","version":"1:26.2.4-1.fc44"},
{"type":"rpm","name":"mesa-filesystem","version":"2:26.2.4-1.fc44"},
{"type":"rpm","name":"gpg-pubkey","version":"aaaa-1"},
{"type":"rpm","name":"gpg-pubkey","version":"bbbb-1"},
{"type":"rpm","name":"","version":"1-1"},{"type":"rpm","name":"blank","version":""},
{"type":"python","name":"pip","version":"25.0"}]}
EOF

    if ! sbom_packages "$dir/sbom.json" "$dir/sbom.out"; then
        fail_self_test "SBOM not parsed"
    fi

    output=$(jq -c . "$dir/sbom.out")
    expected='{"kernel":"7.2.1-ogc4.1.fc44","mesa-filesystem":"1:26.2.4-1.fc44",'
    expected+='"gpg-pubkey":"aaaa-1"}'

    if [ "$output" != "$expected" ]; then
        fail_self_test "SBOM packages not read as changelog.py reads them: $output"
    fi

    echo '{"artifacts":[{"type":"python","name":"pip","version":"26.0"}]}' > "$dir/norpm.json"
    REFUSED=$((REFUSED + 1))

    if sbom_packages "$dir/norpm.json" "$dir/norpm.out" 2> /dev/null; then
        fail_self_test "SBOM without RPMs accepted"
    fi

    # Known-bad: jq's own line, then `lists no RPM` for the wrong reason.
    echo 'not json' > "$dir/notjson.json"
    REFUSED=$((REFUSED + 1))

    if output=$(sbom_packages "$dir/notjson.json" "$dir/notjson.out" 2>&1); then
        fail_self_test "SBOM that is not JSON accepted"
    fi

    if ! grep -q "^changelog: $dir/notjson.json is not a syft SBOM$" <<< "$output" \
        || grep -q '^jq:' <<< "$output"; then
        fail_self_test "SBOM that is not JSON not named: $(head -n1 <<< "$output")"
    fi
}

# self_test_write_images_json <file>: three flavours given out of name order,
# each with its RPMs before and after: a kernel whose subpackage shares its
# version, a removal hidden behind plasma-desktop's version, one package added,
# changed, removed and unchanged everywhere, the closed driver's LTS kernel and
# driver, packages of the two NVIDIA flavours added, changed and removed, one of
# a single flavour.
self_test_write_images_json() {
    local file=$1

    jq -n '
        {"plasma-desktop": "6.7.5-1.fc44", "mesa-filesystem": "1:26.2.4-1.fc44",
         "same": "2-1.fc44"} as $all
        | {"plasma-setup": "6.7.5-1.fc44", "old": "1-1.fc44", "tool": "1.0-1.fc44"} as $before
        | {"new": "3-1.fc44", "tool": "1.1-1.fc44"} as $after
        | {images: [
            {name: "bazzite-mx-nvidia-open",
             prev: ($all + $before + {"kernel-core": "7.2.1-ogc1.fc44",
                "kernel-modules": "7.2.1-ogc1.fc44", "nvidia-kmod-common": "3:615.1-1.fc44",
                "nvtool": "1-1.fc44", "nvgone": "4-1.fc44"}),
             curr: ($all + $after + {"kernel-core": "7.2.2-ogc1.fc44",
                "kernel-modules": "7.2.2-ogc1.fc44", "nvidia-kmod-common": "3:615.2-1.fc44",
                "nvtool": "2-1.fc44", "nvnew": "5-1.fc44"})},
            {name: "bazzite-mx",
             prev: ($all + $before + {"kernel-core": "7.2.1-ogc1.fc44",
                "kernel-modules": "7.2.1-ogc1.fc44", "podman": "1.6.3-1.fc44"}),
             curr: ($all + $after + {"kernel-core": "7.2.2-ogc1.fc44",
                "kernel-modules": "7.2.2-ogc1.fc44", "podman": "1.6.4-1.fc44"})},
            {name: "bazzite-mx-nvidia",
             prev: ($all + $before + {"kernel-core": "6.18.1-ogc1.fc44",
                "kernel-modules": "6.18.1-ogc1.fc44", "nvidia-kmod-common": "3:580.1-1.fc44",
                "libnvidia-ml": "3:580.1-1.fc44", "nvtool": "1-1.fc44",
                "nvgone": "4-1.fc44"}),
             curr: ($all + $after + {"kernel-core": "6.18.2-ogc1.fc44",
                "kernel-modules": "6.18.2-ogc1.fc44", "nvidia-kmod-common": "3:580.2-1.fc44",
                "libnvidia-ml": "3:580.2-1.fc44", "nvtool": "2-1.fc44",
                "nvnew": "5-1.fc44"})}]}' > "$file"
}

# self_test_package_tables <dir>: the change tables of the fixture, against the
# tables changelog.py prints for it, and its Major table, the rows the fixture
# carries; no change table when no flavour is compared.
self_test_package_tables() {
    local dir=$1
    local output expected

    self_test_write_images_json "$dir/images.json"
    output=$(package_tables "$dir/images.json" major)

    if [ "$output" != "$(
        cat << 'EOF'
### Major packages
| Name | Version |
| --- | --- |
| **Kernel** | 7.2.1-ogc1 ➡️ 7.2.2-ogc1 |
| **Kernel (Nvidia LTS)** | 6.18.1-ogc1 ➡️ 6.18.2-ogc1 |
| **Mesa** | 26.2.4-1 |
| **KDE** | 6.7.5-1 |
| **Nvidia Open** | 615.1-1 ➡️ 615.2-1 |
| **Nvidia LTS** | 580.1-1 ➡️ 580.2-1 |
| **Podman** | 1.6.3-1 ➡️ 1.6.4-1 |
EOF
    )" ]; then
        fail_self_test "Major packages table wrong: ${output//$'\n'/ / }"
    fi

    output=$(package_tables "$dir/images.json" changes)
    expected=$(
        cat << 'EOF'
### All Images
| | Name | Previous | New |
| --- | --- | --- | --- |
| ✨ | new | | 3-1 |
| 🔄 | tool | 1.0-1 | 1.1-1 |
| ❌ | old | 1-1 | |

### Nvidia Images
| | Name | Previous | New |
| --- | --- | --- | --- |
| ✨ | nvnew | | 5-1 |
| 🔄 | nvtool | 1-1 | 2-1 |
| ❌ | nvgone | 4-1 | |
EOF
    )

    if [ "$output" != "$expected" ]; then
        fail_self_test "change tables wrong: ${output//$'\n'/ / }"
    fi

    jq '.images[].prev = null' "$dir/images.json" > "$dir/none.json"

    if ! output=$(package_tables "$dir/none.json" changes) || [ -n "$output" ]; then
        fail_self_test "no flavour compared still gave a change table"
    fi
}

# self_test_uncompared_flavour <dir>: a flavour not compared, last by name, its
# versions apart from the others', keeps its major row without an arrow and
# leaves the tables as changelog.py prints them for the two compared flavours
# (its KeyError on the closed driver's names skipped); no arrow to a package the
# compared flavours removed.
self_test_uncompared_flavour() {
    local dir=$1
    local output

    self_test_write_images_json "$dir/images.json"
    jq '(.images[] | select(.name == "bazzite-mx-nvidia-open"))
        |= (.prev = null | .curr.tool = "9.9-1.fc44" | .curr["kernel-core"] = "7.2.9-ogc1.fc44")' \
        "$dir/images.json" > "$dir/gap.json"
    output=$(package_tables "$dir/gap.json" major)

    if ! grep -qxF '| **Nvidia Open** | 615.2-1 |' <<< "$output" \
        || ! grep -qxF '| **Kernel** | 7.2.1-ogc1 ➡️ 7.2.2-ogc1 |' <<< "$output"; then
        fail_self_test "a flavour not compared reached an arrow: ${output//$'\n'/ / }"
    fi

    output=$(package_tables "$dir/gap.json" changes)

    if [ "$output" != "$(package_tables "$dir/images.json" changes)" ]; then
        fail_self_test "a flavour not compared reached the tables: ${output//$'\n'/ / }"
    fi

    # A package the compared flavour removed, still carried by one not compared.
    jq -n '{images: [{name: "bazzite-mx", prev: {code: "1-1.fc44"}, curr: {}},
        {name: "bazzite-mx-nvidia-open", prev: null, curr: {code: "2-1.fc44"}}]}' \
        > "$dir/removed.json"
    output=$(package_tables "$dir/removed.json" major)

    if ! grep -qxF '| **VS Code** | 2-1 |' <<< "$output"; then
        fail_self_test "a removed package drew an arrow: ${output//$'\n'/ / }"
    fi
}

# self_test_package_keys <dir>: the value of the last flavour by name, whatever
# the input order; kerneloops kept on the LTS flavour; one row per new version,
# a hidden package's removal left out.
self_test_package_keys() {
    local dir=$1
    local output

    # The flavours out of name order, each with its own VS Code: the last by
    # name gives the value.
    jq -n '{images: [
        {name: "bazzite-mx-nvidia", prev: {code: "3-1.fc44"}, curr: {code: "3-1.fc44"}},
        {name: "bazzite-mx-nvidia-open", prev: {code: "2-1.fc44"}, curr: {code: "2-1.fc44"}},
        {name: "bazzite-mx", prev: {code: "1-1.fc44"}, curr: {code: "1-1.fc44"}}]}' \
        > "$dir/order.json"
    output=$(package_tables "$dir/order.json" major)

    if ! grep -qxF '| **VS Code** | 2-1 |' <<< "$output"; then
        fail_self_test "the value not taken from the last flavour by name: ${output//$'\n'/ / }"
    fi

    # The LTS flavour alone: a kernel-prefixed name that is no kernel subpackage
    # keeps its key.
    jq -n '{images: [{name: "bazzite-mx-nvidia", prev: {kerneloops: "1-1.fc44"},
        curr: {kerneloops: "2-1.fc44"}}]}' > "$dir/lts.json"
    output=$(package_tables "$dir/lts.json" changes)

    if ! grep -qxF '| 🔄 | kerneloops | 1-1 | 2-1 |' <<< "$output"; then
        fail_self_test "a kernel-prefixed package of the LTS flavour lost: ${output//$'\n'/ / }"
    fi

    # One package per new version: a subpackage sharing the new version, and one
    # sharing the old, left out; so is plasma-desktop's removal.
    jq -n '{images: [{name: "bazzite-mx",
        prev: {"plasma-desktop": "6.7.5-1.fc44", "qt6-qtbase": "6.9-1.fc44",
            "qt6-qtbase-gui": "6.9-1.fc44", "qt6-tool": "6.9-1.fc44"},
        curr: {"qt6-qtbase": "6.10-1.fc44", "qt6-qtbase-gui": "6.10-1.fc44",
            "qt6-tool": "7.0-1.fc44"}}]}' > "$dir/dedup.json"
    output=$(package_tables "$dir/dedup.json" changes)

    if [ "$(grep -c '^| [^|-]' <<< "$output")" -ne 1 ] \
        || ! grep -qxF '| 🔄 | qt6-qtbase | 6.9-1 | 6.10-1 |' <<< "$output"; then
        fail_self_test "not one package per new version: ${output//$'\n'/ / }"
    fi
}

# self_test_header: a first release states no previous one, then its base.
self_test_header() {
    local output
    local expected='This is an automatically generated changelog for release `44.20261009`.

Built on Bazzite [44.20261006](https://github.com/ublue-os/bazzite/releases/tag/44.20261006).'

    output=$(
        RELEASE_TAG=44.20261009
        PREVIOUS_TAG=""
        BASE_VERSIONS=44.20261006
        write_header
    )

    if [ "$output" != "$expected" ]; then
        fail_self_test "header of a first release wrong: ${output//$'\n'/ / }"
    fi
}

# self_test_commits <dir>: a commit row with its link, a `|` escaped in the
# subject and in the author; no section when nothing landed since the previous
# revision; a merge left out; a revision this history lacks, every commit
# listed.
self_test_commits() {
    local dir=$1
    local output head

    git -C "$dir" init -q repo
    git -C "$dir/repo" -c user.name='Te|ster' -c user.email=t@example.invalid \
        -c commit.gpgsign=false commit -q --allow-empty -m 'feat(ci): a | b'
    head=$(git -C "$dir/repo" rev-parse HEAD)
    output=$(cd "$dir/repo" && PREVIOUS_REVISION="" write_commits)

    if ! grep -qxF "| **[${head:0:7}](https://github.com/${REPO}/commit/${head})** |\
 feat(ci): a \| b | Te\|ster |" <<< "$output"; then
        fail_self_test "commit row wrong: ${output//$'\n'/ / }"
    fi

    output=$(cd "$dir/repo" && PREVIOUS_REVISION=$head write_commits)

    if [ -n "$output" ]; then
        fail_self_test "a release of the previous revision listed commits: $output"
    fi

    git -C "$dir/repo" switch -q -c side
    git -C "$dir/repo" -c user.name=Tester -c user.email=t@example.invalid \
        -c commit.gpgsign=false commit -q --allow-empty -m 'fix(ci): on the side'
    git -C "$dir/repo" switch -q -
    git -C "$dir/repo" -c user.name=Tester -c user.email=t@example.invalid \
        -c commit.gpgsign=false merge -q --no-ff -m 'Merge branch side' side
    output=$(cd "$dir/repo" && PREVIOUS_REVISION=$head write_commits)

    if ! grep -qF '| fix(ci): on the side |' <<< "$output" \
        || grep -q 'Merge branch' <<< "$output"; then
        fail_self_test "the commits since the previous revision wrong: ${output//$'\n'/ / }"
    fi

    output=$(cd "$dir/repo" && PREVIOUS_REVISION=$(printf '%040d' 0) write_commits)

    if [ "$(grep -c '^| \*\*\[' <<< "$output")" -ne 2 ]; then
        fail_self_test "a rewritten history not listing every commit: ${output//$'\n'/ / }"
    fi
}

# self_test_write_skopeo_shim <dir>: a skopeo on PATH answering for the previous
# release's images by SKOPEO_SHIM: a digest, a digest after a retry noted on
# stderr, an absent image, or an authentication error.
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

# self_test_write_oras_shim <dir>: an oras on PATH answering by ORAS_SHIM with
# an image without referrers, an SBOM it pulls (refusing any other referrer, an
# attestation listed first), one listing no RPM, an SBOM referrer whose pull
# fails, or a transport error.
self_test_write_oras_shim() {
    local dir=$1

    cat > "$dir/bin/oras" << 'EOF'
#!/usr/bin/env bash
case "$ORAS_SHIM:$1" in
    none:discover)
        echo '{"referrers":[]}'
        ;;
    ok:discover | pull-down:discover | norpm:discover)
        printf '{"referrers":[%s,%s]}\n' \
            '{"artifactType":"application/vnd.dev.sigstore.bundle.v0.3+json","digest":"sha256:9"}' \
            '{"artifactType":"application/vnd.spdx+json","digest":"sha256:8"}'
        ;;
    ok:pull)
        if [[ "$4" != *@sha256:8 ]]; then
            echo "shim: pulled $4, not the SBOM" >&2
            exit 1
        fi

        echo '{"artifacts":[{"type":"rpm","name":"kernel","version":"1"}]}' > "$3/sbom.json"
        ;;
    norpm:pull)
        echo '{"artifacts":[]}' > "$3/sbom.json"
        ;;
    *)
        echo 'Error: failed to resolve ghcr.io: dial tcp: lookup ghcr.io: no such host' >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$dir/bin/oras"
}

# self_test_write_gh_shim <dir>: a gh on PATH answering release download by
# GH_SHIM: ok a packages.json of 44.20260903 carrying bazzite-mx, other-tag one of
# another release, anything else a download that fails.
self_test_write_gh_shim() {
    local dir=$1

    cat > "$dir/bin/gh" << 'EOF'
#!/usr/bin/env bash
case "${GH_SHIM:-}:$2" in
    ok:download)
        echo '{"version":"44.20260903","images":{"bazzite-mx":{"kernel":"0"}}}' > "${!#}"
        ;;
    other-tag:download)
        echo '{"version":"44.20260901","images":{"bazzite-mx":{"kernel":"0"}}}' > "${!#}"
        ;;
    *)
        echo 'release not found' >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$dir/bin/gh"
}

# self_test_fetch_sbom <dir>: an image without an SBOM referrer gives status 2;
# a transport error gives status 1, never taken for a missing SBOM.
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
}

# self_test_inspect_failures <dir>: a base and a previous image skopeo cannot
# inspect stop the notes.
self_test_inspect_failures() {
    local dir=$1

    self_test_write_skopeo_shim "$dir"
    printf '%s\n' image_name=bazzite-mx "digest=sha256:$(printf '%064d' 3)" \
        base_name=ghcr.io/ublue-os/bazzite "base_digest=sha256:$(printf '%064d' 1)" \
        > "$dir/bazzite.env"
    REFUSED=$((REFUSED + 1))

    if (
        ENV_FILES=("$dir/bazzite.env")
        PATH="$dir/bin:$PATH" read_flavours > /dev/null 2>&1
        echo "the notes went on"
    ) > /dev/null; then
        fail_self_test "a base skopeo cannot inspect did not stop the notes"
    fi

    REFUSED=$((REFUSED + 1))

    if (
        # The shim answers 3 on the `@<digest>` reference of the labels.
        IMAGE_NAMES=(bazzite-mx)
        PREVIOUS_TAG=44.20260903
        PATH="$dir/bin:$PATH" SKOPEO_SHIM=ok find_previous_revision > /dev/null 2>&1
        echo "the notes went on"
    ) > /dev/null; then
        fail_self_test "a previous image skopeo cannot inspect did not stop the notes"
    fi
}

# self_test_read_packages <dir>: an image of this release read from its SBOM,
# not from the attestation listed before it, into images.json beside a previous
# release that lacked it, the gap stated on stderr; a previous SBOM listing no
# RPM left null and stated, a previous image without an SBOM stated as a gap. A
# failed pull of the previous SBOM stops the notes; so do an image of this
# release without its SBOM and a transport error on the previous image's digest.
self_test_read_packages() {
    local dir=$1
    local digest output

    self_test_write_oras_shim "$dir"
    self_test_write_skopeo_shim "$dir"
    self_test_write_gh_shim "$dir"
    digest="sha256:$(printf '%064d' 7)"

    if ! output=$(
        IMAGE_NAMES=(bazzite-mx)
        IMAGE_DIGESTS=("$digest")
        PREVIOUS_TAG=44.20260903
        RELEASE_TAG=44.20260904
        PATH="$dir/bin:$PATH" ORAS_SHIM=ok SKOPEO_SHIM=absent GH_SHIM=none read_packages \
            2> /dev/null
        jq -c . "$WORK_DIR/images.json"
        write_package_changes 2> "$dir/gap.err"
    ); then
        fail_self_test "a first release of this image not read: ${output//$'\n'/ / }"
    fi

    if ! grep -qxF '{"images":[{"name":"bazzite-mx","curr":{"kernel":"1"},"prev":null}]}' \
        <<< "$output" \
        || ! grep -qF 'changelog: no package diff for 44.20260904: bazzite-mx not in' \
            "$dir/gap.err"; then
        fail_self_test "a first release of this image not stated on stderr:" \
            "${output//$'\n'/ / } / $(< "$dir/gap.err")"
    fi

    if ! output=$(
        IMAGE_NAMES=(bazzite-mx)
        PREVIOUS_TAG=44.20260903
        PATH="$dir/bin:$PATH" ORAS_SHIM=norpm SKOPEO_SHIM=ok read_previous_packages 0 \
            2> /dev/null && echo read-ok
        cat "$WORK_DIR/prev-0.json"
        echo "$PACKAGE_DIFF_GAPS"
    ) || [ "$(head -n2 <<< "$output" | paste -sd' ' -)" != 'read-ok null' ] \
        || ! grep -qF 'bazzite-mx:44.20260903 without SBOM' <<< "$output"; then
        fail_self_test "a previous SBOM without RPMs not left null: ${output//$'\n'/ / }"
    fi

    REFUSED=$((REFUSED + 1))

    if output=$(
        IMAGE_NAMES=(bazzite-mx)
        PREVIOUS_TAG=44.20260903
        PATH="$dir/bin:$PATH" ORAS_SHIM=pull-down SKOPEO_SHIM=ok read_previous_packages 0 2>&1
    ) || ! grep -q 'oras pull of the SBOM sha256:8 of .* failed' <<< "$output"; then
        fail_self_test "a failed pull of the previous SBOM not refused as such:" \
            "${output//$'\n'/ }"
    fi

    if ! output=$(
        IMAGE_NAMES=(bazzite-mx)
        PREVIOUS_TAG=44.20260903
        PATH="$dir/bin:$PATH" ORAS_SHIM=none SKOPEO_SHIM=ok read_previous_packages 0 \
            2> /dev/null && echo read-ok
        echo "$PACKAGE_DIFF_GAPS"
    ) || ! grep -qx read-ok <<< "$output" \
        || ! grep -qF 'bazzite-mx:44.20260903 without SBOM' <<< "$output"; then
        fail_self_test "a previous image without an SBOM not stated as a gap: $output"
    fi

    REFUSED=$((REFUSED + 1))

    if (
        IMAGE_NAMES=(bazzite-mx)
        IMAGE_DIGESTS=("$digest")
        PREVIOUS_TAG=44.20260903
        PATH="$dir/bin:$PATH" ORAS_SHIM=none SKOPEO_SHIM=ok GH_SHIM=none read_packages \
            > /dev/null 2>&1
        echo "the notes went on"
    ) > /dev/null; then
        fail_self_test "an image of this release without its SBOM did not stop the notes"
    fi

    REFUSED=$((REFUSED + 1))

    if (
        IMAGE_NAMES=(bazzite-mx)
        IMAGE_DIGESTS=("$digest")
        PREVIOUS_TAG=44.20260903
        PATH="$dir/bin:$PATH" ORAS_SHIM=ok SKOPEO_SHIM=auth GH_SHIM=none read_packages \
            > /dev/null 2>&1
        echo "the notes went on"
    ) > /dev/null; then
        fail_self_test "a transport error on the previous image stated as a first release"
    fi
}

# self_test_package_files <dir>: an image's file written from its SBOM; a file
# read for its own version only; the previous packages from the previous
# release's packages.json, its image never read, a flavour it lacks stated as a
# gap; a release whose packages.json gh cannot download, or one of another
# release, left to the SBOMs with the reason; this release's packages.json
# written per image.
self_test_package_files() {
    local dir=$1/packages
    local output expected

    mkdir -p "$dir/bin"
    self_test_write_skopeo_shim "$dir"
    self_test_write_gh_shim "$dir"
    echo '{"artifacts":[{"type":"rpm","name":"kernel","version":"1"}]}' > "$dir/sbom.json"

    if ! packages --sbom "$dir/sbom.json" --image bazzite-mx --version 44.20260904 \
        --out "$dir/packages-bazzite-mx.json" \
        || [ "$(jq -c . "$dir/packages-bazzite-mx.json")" \
            != '{"image":"bazzite-mx","version":"44.20260904","packages":{"kernel":"1"}}' ]; then
        fail_self_test "an image's packages file not written from its SBOM"
    fi

    if ! package_file_for "$dir/packages-bazzite-mx.json" bazzite-mx 44.20260904 \
        "$dir/read.json" || [ "$(jq -c . "$dir/read.json")" != '{"kernel":"1"}' ]; then
        fail_self_test "a packages file not read for its own image and version"
    fi

    REFUSED=$((REFUSED + 1))

    if package_file_for "$dir/packages-bazzite-mx.json" bazzite-mx 44.20260905 \
        "$dir/read.json"; then
        fail_self_test "a packages file for another version was read"
    fi

    if ! output=$(
        IMAGE_NAMES=(bazzite-mx bazzite-mx-nvidia)
        PREVIOUS_TAG=44.20260903
        PATH="$dir/bin:$PATH" GH_SHIM=ok fetch_previous_packages
        PATH="$dir/bin:$PATH" SKOPEO_SHIM=auth read_previous_packages 0
        jq -c . "$WORK_DIR/prev-0.json"
        PATH="$dir/bin:$PATH" SKOPEO_SHIM=auth read_previous_packages 1
        jq -c . "$WORK_DIR/prev-1.json"
        echo "$PACKAGE_DIFF_GAPS"
    ) || [ "$output" != $'{"kernel":"0"}\nnull\nbazzite-mx-nvidia not in 44.20260903' ]; then
        fail_self_test "the previous packages not read from packages.json: ${output//$'\n'/ / }"
    fi

    expected=$'release not found\nchangelog: no packages.json on release 44.20260903, reading the'
    expected+=$' SBOMs\nnone:\n'
    expected+='changelog: packages.json on release 44.20260903 is for 44.20260901, reading'
    expected+=$' the SBOMs\nother-tag:'

    if ! output=$(
        PREVIOUS_TAG=44.20260903
        PATH="$dir/bin:$PATH" GH_SHIM=none fetch_previous_packages 2>&1 \
            && echo "none:$PREVIOUS_PACKAGES"
        PATH="$dir/bin:$PATH" GH_SHIM=other-tag fetch_previous_packages 2>&1 \
            && echo "other-tag:$PREVIOUS_PACKAGES"
    ) || [ "$output" != "$expected" ]; then
        fail_self_test "a release without packages.json, or with another's, not left to the" \
            "SBOMs with the reason: ${output//$'\n'/ / }"
    fi

    echo '{"images":[{"name":"bazzite-mx","curr":{"kernel":"1"},"prev":null},
        {"name":"bazzite-mx-nvidia","curr":{"kernel":"2"},"prev":null}]}' \
        > "$WORK_DIR/images.json"

    expected='{"version":"44.20260904","images":{"bazzite-mx":{"kernel":"1"},'
    expected+='"bazzite-mx-nvidia":{"kernel":"2"}}}'

    if ! (
        RELEASE_TAG=44.20260904
        PACKAGES_OUT=$dir/packages.json
        write_release_packages
    ) || [ "$(jq -c . "$dir/packages.json")" != "$expected" ]; then
        fail_self_test "this release's packages.json not written per image"
    fi
}

# self_test_write_release_shims <dir>: skopeo, oras and gh on PATH answering
# from files under <dir>/answers named after the reference, `/`, `:` and `@`
# made `_`; skopeo calls a reference without a file absent.
self_test_write_release_shims() {
    local dir=$1

    mkdir -p "$dir/bin" "$dir/answers"
    cat > "$dir/bin/skopeo" << 'EOF'
#!/usr/bin/env bash
reference=${!#}
file="$SHIM_ANSWERS/$(tr '/:@' '___' <<< "${reference#docker://}")"

if [ ! -f "$file" ]; then
    echo 'level=fatal msg="reading manifest: manifest unknown"' >&2
    exit 1
fi

cat "$file"
EOF
    cat > "$dir/bin/oras" << 'EOF'
#!/usr/bin/env bash
case "$1" in
    discover)
        cat "$SHIM_ANSWERS/discover_$(tr '/:@' '___' <<< "${!#}")"
        ;;
    pull)
        cp "$SHIM_ANSWERS/pull_$(tr '/:@' '___' <<< "$4")" "$3/sbom.json"
        ;;
esac
EOF
    cat > "$dir/bin/gh" << 'EOF'
#!/usr/bin/env bash
if [ "$2" = download ]; then
    cp "$SHIM_ANSWERS/download_$3" "${!#}" 2> /dev/null
    exit
fi

fields=$(sed -n 's/.*--json \([^ ]*\).*/\1/p' <<< "$*")
jq -c --arg fields "$fields" '[.[] | with_entries(select(.key as $key
    | $fields | split(",") | index($key)))]' "$SHIM_ANSWERS/releases"
EOF
    chmod +x "$dir/bin/skopeo" "$dir/bin/oras" "$dir/bin/gh"
}

# self_test_answer <dir> <reference> <json>: what the shims give for it.
self_test_answer() {
    local dir=$1
    local reference=$2
    local json=$3
    local file

    file=$(tr '/:@' '___' <<< "$reference")
    echo "$json" > "$dir/answers/$file"
}

# self_test_release <dir>: release run end to end, with an empty handwritten
# text as release.yml passes it, on two flavours whose bases disagree on their
# version, against a previous release picked by publication, with one commit
# since its revision: the title on the highest base, the header, the Major
# arrows and a major package new since then, the commit, the change table, the
# rebase commands and only the SBOM fallback on stderr. Run again from the build
# jobs' packages files and the previous release's packages.json, with every SBOM
# pull gone and a handwritten text, it writes the same notes with the text in
# place of the generated line, and this release's packages.json.
self_test_release() {
    local dir=$1/release
    local registry=ghcr.io/matrixdj96 base=ghcr.io/ublue-os
    local tag_url=https://github.com/ublue-os/bazzite/releases/tag/
    local sbom='{"artifacts":[{"type":"rpm","name":"kernel-core","version":"%s"},
        {"type":"rpm","name":"foo","version":"%s"}%s]}'
    local handwritten='Hand-written: the `stable` text, as typed.'
    local revision title notes digest referrers

    self_test_write_release_shims "$dir"
    git -C "$dir" init -q repo
    git -C "$dir/repo" -c user.name=Tester -c user.email=t@example.invalid \
        -c commit.gpgsign=false commit -q --allow-empty -m 'feat(ci): the previous release'
    revision=$(git -C "$dir/repo" rev-parse HEAD)
    git -C "$dir/repo" -c user.name=Tester -c user.email=t@example.invalid \
        -c commit.gpgsign=false commit -q --allow-empty -m 'fix(ci): since then'

    printf '%s\n' image_name=bazzite-mx digest=sha256:c1 "base_name=$base/bazzite" \
        base_digest=sha256:b1 > "$dir/one.env"
    printf '%s\n' image_name=bazzite-mx-nvidia digest=sha256:c2 \
        "base_name=$base/bazzite-nvidia" base_digest=sha256:b2 > "$dir/two.env"
    self_test_answer "$dir" releases '[
        {"tagName":"44.20261001.10","publishedAt":"2026-10-01T20:00:00Z","isDraft":false},
        {"tagName":"44.20261001.9","publishedAt":"2026-10-01T08:00:00Z","isDraft":false}]'
    self_test_answer "$dir" "$base/bazzite@sha256:b1" '{"Labels":{
        "org.opencontainers.image.version":"44.20261006.9"}}'
    self_test_answer "$dir" "$base/bazzite-nvidia@sha256:b2" '{"Labels":{
        "org.opencontainers.image.version":"44.20261006.10"}}'
    self_test_answer "$dir" "$registry/bazzite-mx:44.20261001.10" '{"Digest":"sha256:p1"}'
    self_test_answer "$dir" "$registry/bazzite-mx-nvidia:44.20261001.10" \
        '{"Digest":"sha256:p2"}'
    self_test_answer "$dir" "$registry/bazzite-mx@sha256:p1" \
        "{\"Labels\":{\"org.opencontainers.image.revision\":\"$revision\"}}"

    for digest in c1 c2 p1 p2; do
        referrers='{"referrers":[{"artifactType":"application/vnd.spdx+json",'
        referrers+="\"digest\":\"sha256:s$digest\"}]}"
        self_test_answer "$dir" "discover_$registry/bazzite-mx@sha256:$digest" "$referrers"
        self_test_answer "$dir" "discover_$registry/bazzite-mx-nvidia@sha256:$digest" \
            "$referrers"
    done

    self_test_answer "$dir" "pull_$registry/bazzite-mx@sha256:sc1" \
        "$(printf "$sbom" 7.2.2-1.fc44 1.1-1.fc44 \
            ',{"type":"rpm","name":"Sunshine","version":"2-1"}')"
    self_test_answer "$dir" "pull_$registry/bazzite-mx@sha256:sp1" \
        "$(printf "$sbom" 7.2.1-1.fc44 1.0-1.fc44 '')"
    self_test_answer "$dir" "pull_$registry/bazzite-mx-nvidia@sha256:sc2" \
        "$(printf "$sbom" 6.18.2-1.fc44 1.1-1.fc44 '')"
    self_test_answer "$dir" "pull_$registry/bazzite-mx-nvidia@sha256:sp2" \
        "$(printf "$sbom" 6.18.1-1.fc44 1.0-1.fc44 '')"

    if ! title=$(
        PATH="$dir/bin:$PATH" SHIM_ANSWERS=$dir/answers GIT_DIR=$dir/repo/.git \
            "$0" release --release-tag 44.20261009 --out "$dir/notes.md" --handwritten "" \
            "$dir/one.env" "$dir/two.env" 2> "$dir/release.err"
    ); then
        fail_self_test "release run failed: $(< "$dir/release.err")"
    fi

    notes=$(< "$dir/notes.md")

    if [ "$title" != '44.20261009: Stable (Bazzite 44.20261006.10)' ] \
        || [ "$(< "$dir/release.err")" \
            != 'changelog: no packages.json on release 44.20261001.10, reading the SBOMs' ] \
        || [ "$(grep '^###' <<< "$notes" | paste -sd, -)" \
            != '### Major packages,### Commits,### All Images,### How to rebase' ] \
        || ! grep -qxF 'This is an automatically generated changelog for release `44.20261009`.' \
            <<< "$notes" \
        || ! grep -qF 'From previous `stable` version `44.20261001.10` there' <<< "$notes" \
        || ! grep -qxF "Built on Bazzite [44.20261006.9](${tag_url}44.20261006.9),\
 [44.20261006.10](${tag_url}44.20261006.10)." <<< "$notes" \
        || ! grep -qxF '| **Kernel** | 7.2.1-1 ➡️ 7.2.2-1 |' <<< "$notes" \
        || ! grep -qxF '| **Kernel (Nvidia LTS)** | 6.18.1-1 ➡️ 6.18.2-1 |' <<< "$notes" \
        || ! grep -qxF '| **Sunshine** | 2-1 |' <<< "$notes" \
        || ! grep -qF '| fix(ci): since then | Tester |' <<< "$notes" \
        || ! grep -qxF '| 🔄 | foo | 1.0-1 | 1.1-1 |' <<< "$notes" \
        || [ "$(tail -n 8 <<< "$notes")" != "$(
            cat << 'EOF'
### How to rebase
For current users, type the following to rebase to this version:
```bash
# For this branch (if latest):
ujust migrate stable
# For this specific image:
ujust migrate 44.20261009
```
EOF
        )" ]; then
        fail_self_test "release notes wrong: title '$title', stderr '$(< "$dir/release.err")'," \
            "notes: ${notes//$'\n'/ / }"
    fi

    mkdir -p "$dir/packages"
    rm -f "$dir/answers"/pull_*
    echo '{"image":"bazzite-mx","version":"44.20261009","packages":{"kernel-core":"7.2.2-1.fc44",
        "foo":"1.1-1.fc44","Sunshine":"2-1"}}' > "$dir/packages/packages-bazzite-mx.json"
    echo '{"image":"bazzite-mx-nvidia","version":"44.20261009","packages":{
        "kernel-core":"6.18.2-1.fc44","foo":"1.1-1.fc44"}}' \
        > "$dir/packages/packages-bazzite-mx-nvidia.json"
    self_test_answer "$dir" download_44.20261001.10 '{"version":"44.20261001.10","images":{
        "bazzite-mx":{"kernel-core":"7.2.1-1.fc44","foo":"1.0-1.fc44"},
        "bazzite-mx-nvidia":{"kernel-core":"6.18.1-1.fc44","foo":"1.0-1.fc44"}}}'

    if ! (
        PATH="$dir/bin:$PATH" SHIM_ANSWERS=$dir/answers GIT_DIR=$dir/repo/.git \
            "$0" release --release-tag 44.20261009 --out "$dir/notes-files.md" \
            --handwritten "$handwritten" \
            --packages-dir "$dir/packages" --packages-out "$dir/packages.json" \
            "$dir/one.env" "$dir/two.env" > /dev/null 2> "$dir/release-files.err"
    ) || [ -s "$dir/release-files.err" ] \
        || [ "$(head -n 1 "$dir/notes-files.md")" != "$handwritten" ] \
        || ! cmp -s <(tail -n +2 "$dir/notes.md") <(tail -n +2 "$dir/notes-files.md") \
        || [ "$(jq -c '.version, (.images | keys)' "$dir/packages.json" | paste -sd' ' -)" \
            != '"44.20261009" ["bazzite-mx","bazzite-mx-nvidia"]' ]; then
        fail_self_test "release from packages files differs: $(< "$dir/release-files.err")," \
            "$(diff "$dir/notes.md" "$dir/notes-files.md" | head -n 4 | paste -sd' ' -)"
    fi
}

self_test() {
    local dir

    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    mkdir -p "$dir/bin"

    self_test_previous_tag
    self_test_sbom_packages "$dir"
    self_test_package_tables "$dir"
    self_test_uncompared_flavour "$dir"
    self_test_package_keys "$dir"
    self_test_header
    self_test_commits "$dir"
    self_test_inspect_retry_note "$dir"
    self_test_fetch_sbom "$dir"
    self_test_read_packages "$dir"
    self_test_package_files "$dir"
    self_test_release "$dir"
    self_test_inspect_failures "$dir"

    echo "self-test ok: previous tag picked 3 ways, SBOM read as changelog.py reads it," \
        "change tables equal to changelog.py's, Major rows the present ones," \
        "header and commits written," \
        "a retried inspect kept clean," \
        "SBOM absence told from a transport error, packages read with their gaps," \
        "packages files written and read before the SBOMs," \
        "a release written end to end from SBOMs and from packages files" \
        "with a handwritten text," \
        "$REFUSED bad inputs refused"
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
    packages)
        shift
        packages "$@"
        ;;
    *)
        exit_with_error "usage: changelog.sh release --release-tag <tag> --out <file>" \
            "[--handwritten <text>] [--packages-dir <dir>] [--packages-out <file>]" \
            "<env-file>... |" \
            "packages --sbom <file> --image <name> --version <tag> --out <file> |" \
            "--self-test"
        ;;
esac
