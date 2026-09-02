#!/usr/bin/env bash
# Gates the step from a pushed :staging image to a tag a host may pull. Images
# are named by digest, never by a :staging tag a later run reuses.
#
# For each image: the labels the build stamped are checked; the three readings
# of the base (version job, build, manifest label) must agree; the flavour's own
# base must be refused by our key and our attestation lookup (so neither
# verifier is a no-op); the image must pass both; then its digest is copied onto
# :<tag>. :stable moves only after the last image passed.
#
# Usage: gate-release.sh release --release-tag <tag> --revision <sha> \
#            [--promote] --base <flavour>=<digest>... <env-file>...
#          --release-tag <tag>  the tag being released, <fedora>.<yyyymmdd>[.N]
#          --revision <sha>     the full commit sha the images were built from
#          --promote            move :stable onto the images once all passed
#          --base <flavour>=<digest>
#                               the base digest the version job resolved, one
#                               per flavour
#          <env-file>...        one per flavour, from the build job: image_name,
#                               digest, base_name, base_digest
#        gate-release.sh promote --release-tag <tag>
#          re-verify the images :<tag> points at, then move :stable onto them
#        gate-release.sh --self-test
# Output: one line per check passed. `release` prints `labels ok:`, `base ok:`,
#   `negative controls ok:`, `verified:` and `tagged:`, then
#   `gate ok: <tag> on N images, promote=<yes|no>`; `promote` checks the title,
#   the vendor and the version with no line of its own and has no build to hold
#   the revision and the base to, so it prints `negative controls ok:`,
#   `verified:` and `tagged:`, then `promote ok: :stable -> <tag> on N images`.
#   The first refusal is one `gate-release: …` line on stderr.
# Exit status: 0 every image passed and the tags were written; 1 on a bad
#   argument, the first image refused, or a tag that cannot be read or written.
#   A release tag that already points at the same digest is left as it is; one
#   pointing elsewhere is refused.
# Needs skopeo, cosign, gh (GH_TOKEN), a docker login to ghcr.io (cosign and gh
#   read the docker credentials) and cosign.pub at the repository root, the
#   directory two levels above this script.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

VENDOR=matrixdj96
COSIGN_PUB=$(dirname "$0")/../../cosign.pub

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# --- the release being gated --------------------------------------------------
#
# Set by parse_release_arguments, read by the check_* functions, gate_image and
# release. VERSION_JOB_BASES maps a flavour to the base digest the version job
# resolved; the VERIFIED_* arrays grow as images pass.

RELEASE_TAG=""
REVISION=""
PROMOTE=no
ENV_FILES=()
declare -A VERSION_JOB_BASES=()
VERIFIED_IMAGES=()
VERIFIED_DIGESTS=()

# --- registry reads -----------------------------------------------------------

# retry <command>...: three attempts 15 s apart, status 1 when all three fail.
retry() {
    local attempt

    for attempt in 1 2 3; do
        if "$@"; then
            return 0
        fi

        if [ "$attempt" -eq 3 ]; then
            return 1
        fi

        sleep 15
    done
}

# inspect_ref <reference>: the manifest of an image, JSON on stdout; status 1
# with skopeo's reason on one `gate-release:` line.
inspect_ref() {
    local reference=$1
    local error_file=$WORK_DIR/inspect-ref.err
    local manifest error

    if ! manifest=$(skopeo inspect --retry-times 3 --no-tags "docker://$reference" \
        2> "$error_file"); then
        error=$(< "$error_file")
        print_error "skopeo inspect $reference: ${error//$'\n'/ }"
        return 1
    fi

    echo "$manifest"
}

# label_of <manifest json> <label>: the label's value, empty when absent.
label_of() {
    local manifest_json=$1
    local label=$2

    jq -r --arg label "$label" '.Labels[$label] // empty' <<< "$manifest_json"
}

# classify_tag <inspect status> <inspect stderr> <digest found> <digest wanted>:
# prints `free` for a tag that does not exist and `same` for one already at the
# wanted digest; fails on anything else, because a release tag is never
# re-pointed and an unreadable registry is never taken for an empty one.
classify_tag() {
    local status=$1
    local stderr=${2//$'\n'/ }
    local found=$3
    local wanted=$4

    if [ "$status" -eq 0 ]; then
        if [ "$found" != "$wanted" ]; then
            print_error "tag exists and points at $found, not $wanted: a release tag never moves"
            return 1
        fi

        echo same
        return 0
    fi

    if absent_error "$stderr"; then
        echo free
        return 0
    fi

    print_error "could not tell whether the tag exists: ${stderr:-no output from skopeo}"
    return 1
}

# tag_state <image> <tag> <digest>: classify_tag on the live registry.
tag_state() {
    local image=$1
    local tag=$2
    local digest=$3
    local reference="docker://${REGISTRY}/${image}:${tag}"
    local error_file=$WORK_DIR/inspect.err
    local inspected status found=""

    if inspected=$(skopeo inspect --retry-times 3 --no-tags "$reference" 2> "$error_file"); then
        status=0
        found=$(jq -r '.Digest' <<< "$inspected")
    else
        status=$?
    fi

    classify_tag "$status" "$(cat "$error_file")" "$found" "$digest"
}

# cosign_rejected <cosign stderr>: status 0 only when cosign refused the signing
# material, never on a transport error. The second shape comes from an image
# whose provenance bundle, signed with a certificate, cosign reads before the
# .sig (docs/gotchas.md § `cosign verify --key` reads a certificate-signed
# referrer before the `.sig`).
cosign_rejected() {
    local message=$1

    grep -qE 'no matching signatures|no matching attestations: expected key signature' \
        <<< "$message"
}

# --- the checks on one image --------------------------------------------------

# check_labels <manifest json> <image name> <tag> <revision>: the title, the
# vendor, the version and, when a revision is given, the revision the build
# stamped. An empty revision skips that check (promote mode).
check_labels() {
    local manifest_json=$1
    local image_name=$2
    local tag=$3
    local revision=$4
    local title vendor version stamped_revision

    title=$(label_of "$manifest_json" org.opencontainers.image.title)
    vendor=$(label_of "$manifest_json" org.opencontainers.image.vendor)
    version=$(label_of "$manifest_json" org.opencontainers.image.version)
    stamped_revision=$(label_of "$manifest_json" org.opencontainers.image.revision)

    if [ "$title" != "$image_name" ]; then
        print_error "title is '$title', expected '$image_name'"
        return 1
    fi

    if [ "$vendor" != "$VENDOR" ]; then
        print_error "vendor is '$vendor', expected '$VENDOR'"
        return 1
    fi

    if [ "$version" != "$tag" ]; then
        print_error "version is '$version', expected '$tag'"
        return 1
    fi

    if [ -n "$revision" ] && [ "$stamped_revision" != "$revision" ]; then
        print_error "revision is '$stamped_revision', expected '$revision'"
        return 1
    fi
}

# base_of <manifest json>: the base the manifest was built from, as
# <name>@<digest>, read off the labels image-labels.sh wrote; refused when
# either label is missing or malformed.
base_of() {
    local manifest_json=$1
    local name digest

    name=$(label_of "$manifest_json" org.opencontainers.image.base.name)
    digest=$(label_of "$manifest_json" org.opencontainers.image.base.digest)

    if [[ ! "$name" =~ ^ghcr\.io/ublue-os/[a-z-]+:stable$ ]] \
        || [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        print_error "no base labels on the manifest: name '$name', digest '$digest'"
        return 1
    fi

    echo "${name%:stable}@${digest}"
}

# check_base <flavour> <version job digest> <base name> <build digest>
# <manifest json>: the base the version job resolved, the one the build job
# wrote in its env file and the one the manifest's label names are the same
# digest. A base that moved between the jobs of one run, or a build that
# resolved on its own, is refused with the three readings side by side.
check_base() {
    local flavour=$1
    local version_job_digest=$2
    local base_name=$3
    local build_digest=$4
    local manifest_json=$5
    local labelled

    if ! labelled=$(base_of "$manifest_json"); then
        return 1
    fi

    if [ "$build_digest" != "$version_job_digest" ] \
        || [ "$labelled" != "${base_name}@${version_job_digest}" ]; then
        print_error "base digests disagree for $flavour: version job $version_job_digest," \
            "build $build_digest, manifest label ${labelled#*@}"
        return 1
    fi

    echo "base ok: ${base_name}@${version_job_digest} (version job, build and manifest label agree)"
}

# negative_controls <base reference>: the flavour's own base, signed by
# ublue-os, is rejected by our key and by our attestation lookup. For cosign
# only a signature-class rejection counts: a network error also exits non-zero
# and would pass a control that saw nothing. The attestation half reads the
# status alone: gh prints no stable line for "no attestation".
negative_controls() {
    local reference=$1
    local cosign_output

    if cosign_output=$(cosign verify --key "$COSIGN_PUB" "$reference" 2>&1 > /dev/null); then
        print_error "negative control: cosign.pub accepted the signature of $reference"
        return 1
    fi

    if ! cosign_rejected "$cosign_output"; then
        print_error "negative control inconclusive:" \
            "cosign failed on $reference for another reason: ${cosign_output//$'\n'/ }"
        return 1
    fi

    if gh attestation verify "oci://$reference" --repo "$REPO" > /dev/null 2>&1; then
        print_error "negative control: an attestation of $REPO was found on $reference"
        return 1
    fi

    echo "negative controls ok: $reference rejected by cosign.pub and by the attestation lookup"
}

# verify_image <reference>: the image's signature against cosign.pub and its
# build attestation against this repository.
verify_image() {
    local reference=$1
    local output

    if ! output=$(retry cosign verify --key "$COSIGN_PUB" "$reference" 2>&1); then
        print_error "cosign verify failed on $reference: ${output//$'\n'/ }"
        return 1
    fi

    if ! output=$(retry gh attestation verify "oci://$reference" --repo "$REPO" 2>&1); then
        print_error "gh attestation verify failed on $reference: ${output//$'\n'/ }"
        return 1
    fi

    echo "verified: $reference (cosign.pub, attestation of $REPO)"
}

# --- registry writes ----------------------------------------------------------

# copy_tag <image> <digest> <tag>: the digest copied onto <image>:<tag>.
copy_tag() {
    local image=$1
    local digest=$2
    local tag=$3
    local output

    if ! output=$(retry skopeo copy --preserve-digests "docker://${REGISTRY}/${image}@${digest}" \
        "docker://${REGISTRY}/${image}:${tag}" 2>&1); then
        print_error "skopeo copy to ${image}:${tag} failed: ${output//$'\n'/ }"
        return 1
    fi

    echo "tagged: ${image}:${tag} -> ${digest}"
}

# --- release ------------------------------------------------------------------

# add_version_job_base <flavour>=<digest>: one --base option into
# VERSION_JOB_BASES; exits 1 on a malformed one.
add_version_job_base() {
    local option=$1
    local flavour digest

    if [[ ! "$option" =~ ^([a-z-]+)=(sha256:[0-9a-f]{64})$ ]]; then
        exit_with_error "--base must be <flavour>=sha256:<64 hex>: '$option'"
    fi

    flavour=${BASH_REMATCH[1]}
    digest=${BASH_REMATCH[2]}
    VERSION_JOB_BASES[$flavour]=$digest
}

# parse_release_arguments <release arguments>...: RELEASE_TAG, REVISION,
# PROMOTE, VERSION_JOB_BASES and ENV_FILES from the command line; exits 1 on an
# unknown option, one without its value or a malformed --base.
parse_release_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --release-tag)
                require_option_value "$1" "${2:-}"
                RELEASE_TAG=$2
                shift 2
                ;;
            --revision)
                require_option_value "$1" "${2:-}"
                REVISION=$2
                shift 2
                ;;
            --promote)
                PROMOTE=yes
                shift
                ;;
            --base)
                require_option_value "$1" "${2:-}"
                add_version_job_base "$2"
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

# check_release_options: one env file and one --base per flavour, or exit 1.
check_release_options() {
    local expected_count

    expected_count=$(wc -w <<< "$PACKAGES")

    if [ "${#ENV_FILES[@]}" -ne "$expected_count" ]; then
        exit_with_error "expected $expected_count env files (one per flavour)," \
            "got ${#ENV_FILES[@]}"
    fi

    if [ "${#VERSION_JOB_BASES[@]}" -ne "$expected_count" ]; then
        exit_with_error "expected $expected_count --base <flavour>=<digest>" \
            "(the version job's, one per flavour), got ${#VERSION_JOB_BASES[@]}"
    fi
}

# check_env_files: every env file read, its flavour covered by a --base and
# given once, or exit 1. With check_release_options, all before the first
# registry call.
check_env_files() {
    local file flavour
    local -A env_file_of_flavour=()

    for file in "${ENV_FILES[@]}"; do
        read_env "$file"

        flavour=${base_name#"${BASE_REGISTRY}/"}

        if [ -z "${VERSION_JOB_BASES[$flavour]:-}" ]; then
            exit_with_error "$file: no --base for ${flavour}:" \
                "the version job resolved ${!VERSION_JOB_BASES[*]}"
        fi

        if [ -n "${env_file_of_flavour[$flavour]:-}" ]; then
            exit_with_error "$file: flavour ${flavour} given twice," \
                "already in ${env_file_of_flavour[$flavour]}"
        fi

        env_file_of_flavour[$flavour]=$file
    done
}

# gate_image <env file>: every check on the image of one env file, then its
# digest onto :<tag>; the script stops at the first refusal. A passed image
# joins the VERIFIED_* arrays for the promotion.
gate_image() {
    local file=$1
    local flavour reference manifest_json

    read_env "$file"

    flavour=${base_name#"${BASE_REGISTRY}/"}
    reference="${REGISTRY}/${image_name}@${digest}"
    echo "== ${image_name}@${digest} (from $file)"

    if ! manifest_json=$(inspect_ref "$reference"); then
        exit 1
    fi

    if ! check_labels "$manifest_json" "$image_name" "$RELEASE_TAG" "$REVISION"; then
        exit 1
    fi

    echo "labels ok: title ${image_name}, version ${RELEASE_TAG}, revision ${REVISION:0:7}"

    if ! check_base "$flavour" "${VERSION_JOB_BASES[$flavour]}" "$base_name" "$base_digest" \
        "$manifest_json"; then
        exit 1
    fi

    if ! negative_controls "${base_name}@${base_digest}"; then
        exit 1
    fi

    if ! verify_image "$reference"; then
        exit 1
    fi

    tag_release_image "$image_name" "$digest"
    VERIFIED_IMAGES+=("$image_name")
    VERIFIED_DIGESTS+=("$digest")
}

# tag_release_image <image> <digest>: the digest onto <image>:<tag>, left as it
# is when the tag already points there; exits 1 when the tag cannot be read,
# already points at another digest, or cannot be copied.
tag_release_image() {
    local image=$1
    local digest=$2
    local state

    if ! state=$(tag_state "$image" "$RELEASE_TAG" "$digest"); then
        exit 1
    fi

    case "$state" in
        same)
            echo "tag ${image}:${RELEASE_TAG} already points at ${digest}"
            ;;
        free)
            if ! copy_tag "$image" "$digest" "$RELEASE_TAG"; then
                exit 1
            fi
            ;;
    esac
}

# promote_verified_images: :stable onto every image that passed; exits 1 on a
# copy that fails. It runs only once every image has: a flavour refused earlier
# leaves no sibling promoted on its own (docs/workflow.md § The release run).
promote_verified_images() {
    local i

    for i in "${!VERIFIED_IMAGES[@]}"; do
        if ! copy_tag "${VERIFIED_IMAGES[$i]}" "${VERIFIED_DIGESTS[$i]}" stable; then
            exit 1
        fi
    done
}

# release <arguments>...: the gate on every env file, then the promotion when
# asked for.
release() {
    local file

    parse_release_arguments "$@"
    check_release_options
    check_env_files

    for file in "${ENV_FILES[@]}"; do
        gate_image "$file"
    done

    if [ "$PROMOTE" = yes ]; then
        promote_verified_images
    fi

    echo "gate ok: ${RELEASE_TAG} on ${#ENV_FILES[@]} images, promote=${PROMOTE}"
}

# --- promote ------------------------------------------------------------------

# verify_tagged_image <package> <tag>: the image :<tag> points at re-verified
# (labels, negative controls on its base, signature and attestation), its digest
# joining the VERIFIED_* arrays; exits 1 on the first check that fails.
verify_tagged_image() {
    local package=$1
    local tag=$2
    local manifest_json digest base

    echo "== ${package}:${tag}"

    if ! manifest_json=$(inspect_ref "${REGISTRY}/${package}:${tag}"); then
        exit 1
    fi

    digest=$(jq -r '.Digest' <<< "$manifest_json")

    if ! check_labels "$manifest_json" "$package" "$tag" ""; then
        exit 1
    fi

    if ! base=$(base_of "$manifest_json"); then
        exit 1
    fi

    if ! negative_controls "$base"; then
        exit 1
    fi

    if ! verify_image "${REGISTRY}/${package}@${digest}"; then
        exit 1
    fi

    VERIFIED_IMAGES+=("$package")
    VERIFIED_DIGESTS+=("$digest")
}

# promote <arguments>...: :stable onto the images of one released tag, once
# every one of them passed; exits 1 on an unknown option, a malformed tag, an
# image that fails or a :stable copy that fails.
promote() {
    local tag="" package

    while [ $# -gt 0 ]; do
        case "$1" in
            --release-tag)
                require_option_value "$1" "${2:-}"
                tag=$2
                shift 2
                ;;
            *)
                exit_with_error "unknown option '$1'"
                ;;
        esac
    done

    if [[ ! "$tag" =~ $TAG_SHAPE ]]; then
        exit_with_error "--release-tag must be <fedora>.<yyyymmdd>[.N]: '$tag'"
    fi

    for package in $PACKAGES; do
        verify_tagged_image "$package" "$tag"
    done

    promote_verified_images
    echo "promote ok: :stable -> ${tag} on $(wc -w <<< "$PACKAGES") images"
}

# --- self-test ----------------------------------------------------------------
#
# Fixtures: one env file, one manifest and the digests below. The release on a
# stubbed registry comes last, because the stubs replace the registry functions
# for the rest of the process.

SELF_TEST_TAG=44.20260903
SELF_TEST_REVISION=8cfea1732f154089321597d3c52084db3e9dd8ce
SELF_TEST_WRONG_REVISION=0000000000000000000000000000000000000000
SELF_TEST_IMAGE_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SELF_TEST_BASE_DIGEST=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76
SELF_TEST_OTHER_DIGEST=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
SELF_TEST_MANIFEST=""

# self_test_write_manifest: SELF_TEST_MANIFEST, the manifest of a bazzite-mx
# image with every label the gate reads.
self_test_write_manifest() {
    SELF_TEST_MANIFEST=$(
        cat << EOF
{"Digest":"$SELF_TEST_IMAGE_DIGEST","Labels":{
 "org.opencontainers.image.title":"bazzite-mx",
 "org.opencontainers.image.vendor":"matrixdj96",
 "org.opencontainers.image.version":"$SELF_TEST_TAG",
 "org.opencontainers.image.revision":"$SELF_TEST_REVISION",
 "org.opencontainers.image.base.name":"ghcr.io/ublue-os/bazzite:stable",
 "org.opencontainers.image.base.digest":"$SELF_TEST_BASE_DIGEST"}}
EOF
    )
}

# self_test_write_env <file> <flavour>: the env file of one flavour's image.
self_test_write_env() {
    local file=$1
    local flavour=$2

    printf '%s\n' "image_name=$(image_of "$flavour")" \
        "digest=$SELF_TEST_IMAGE_DIGEST" \
        "base_name=${BASE_REGISTRY}/${flavour}" \
        "base_digest=$SELF_TEST_BASE_DIGEST" > "$file"
}

# self_test_labels_refused <manifest json> <image name> <revision>: one
# known-bad manifest refused by check_labels.
self_test_labels_refused() {
    local manifest_json=$1
    local image_name=$2
    local revision=$3

    REFUSED=$((REFUSED + 1))

    if check_labels "$manifest_json" "$image_name" "$SELF_TEST_TAG" "$revision" \
        > /dev/null 2>&1; then
        fail_self_test "known-bad manifest $REFUSED accepted"
    fi
}

# self_test_labels: the manifest accepted with and without the revision check; a
# changed version, a wrong revision, the base's title and the base's vendor
# refused.
self_test_labels() {
    local changed

    if ! check_labels "$SELF_TEST_MANIFEST" bazzite-mx "$SELF_TEST_TAG" "$SELF_TEST_REVISION"; then
        fail_self_test "matching labels refused"
    fi

    if ! check_labels "$SELF_TEST_MANIFEST" bazzite-mx "$SELF_TEST_TAG" ""; then
        fail_self_test "labels refused with the revision check off"
    fi

    changed=$(jq -c '.Labels["org.opencontainers.image.version"] = "44.20260902"' \
        <<< "$SELF_TEST_MANIFEST")
    self_test_labels_refused "$changed" bazzite-mx "$SELF_TEST_REVISION"

    self_test_labels_refused "$SELF_TEST_MANIFEST" bazzite-mx "$SELF_TEST_WRONG_REVISION"

    changed=$(jq -c '.Labels["org.opencontainers.image.title"] = "Bazzite"' \
        <<< "$SELF_TEST_MANIFEST")
    self_test_labels_refused "$changed" bazzite-mx "$SELF_TEST_REVISION"

    changed=$(jq -c '.Labels["org.opencontainers.image.vendor"] = "ublue-os"' \
        <<< "$SELF_TEST_MANIFEST")
    self_test_labels_refused "$changed" bazzite-mx "$SELF_TEST_REVISION"
}

# self_test_base_of: the base read off the labels; a manifest without the base
# digest and one naming a foreign base refused.
self_test_base_of() {
    local expected="ghcr.io/ublue-os/bazzite@$SELF_TEST_BASE_DIGEST"
    local no_digest foreign_base bad

    if [ "$(base_of "$SELF_TEST_MANIFEST")" != "$expected" ]; then
        fail_self_test "base not read from the labels"
    fi

    no_digest=$(jq -c 'del(.Labels["org.opencontainers.image.base.digest"])' \
        <<< "$SELF_TEST_MANIFEST")
    foreign_base=$(jq -c --arg name docker.io/library/fedora:44 \
        '.Labels["org.opencontainers.image.base.name"] = $name' <<< "$SELF_TEST_MANIFEST")
    for bad in "$no_digest" "$foreign_base"; do
        REFUSED=$((REFUSED + 1))

        if base_of "$bad" > /dev/null 2>&1; then
            fail_self_test "manifest without a usable base $REFUSED accepted"
        fi
    done
}

# self_test_classify_tag: a missing tag is free and a tag at the wanted digest
# is same; a tag at another digest and an unreadable registry refused.
self_test_classify_tag() {
    local missing='reading manifest 44.20260903 in ghcr.io/x: manifest unknown'
    local output

    if [ "$(classify_tag 1 "$missing" '' sha256:aaaa)" != free ]; then
        fail_self_test "missing tag not classified free"
    fi

    if [ "$(classify_tag 0 '' sha256:aaaa sha256:aaaa)" != same ]; then
        fail_self_test "same digest not classified same"
    fi

    REFUSED=$((REFUSED + 1))

    if classify_tag 0 '' sha256:bbbb sha256:aaaa > /dev/null 2>&1; then
        fail_self_test "tag state $REFUSED accepted"
    fi

    REFUSED=$((REFUSED + 1))

    if output=$(classify_tag 1 $'WARN retrying (1/3)\nunauthorized: authentication required' \
        '' sha256:aaaa 2>&1); then
        fail_self_test "tag state $REFUSED accepted"
    fi

    if [ "$(grep -c '' <<< "$output")" -ne 1 ]; then
        fail_self_test "a failed inspect not folded into one line: ${output//$'\n'/ }"
    fi

    # Known-bad: a skopeo that failed writing nothing left the line on a bare
    # colon.
    REFUSED=$((REFUSED + 1))

    if output=$(classify_tag 1 '' '' sha256:aaaa 2>&1); then
        fail_self_test "a failed inspect without output classified"
    fi

    if ! grep -q 'could not tell whether the tag exists: no output from skopeo$' <<< "$output"; then
        fail_self_test "a failed inspect without output not named: ${output:-no output}"
    fi
}

# self_test_inspect_retry_note: a skopeo that retried and then succeeded gives
# the manifest alone, its note on neither channel.
self_test_inspect_retry_note() {
    local error_file=$WORK_DIR/retry-note.err
    local output

    skopeo() {
        echo 'WARN retrying (1/3)' >&2
        echo "$SELF_TEST_MANIFEST"
    }

    if ! output=$(inspect_ref "$REGISTRY/bazzite-mx:$SELF_TEST_TAG" 2> "$error_file"); then
        fail_self_test "a skopeo that retried and succeeded was read as a failure"
    fi

    if [ "$output" != "$SELF_TEST_MANIFEST" ]; then
        fail_self_test "the retry note reached the manifest: ${output//$'\n'/ }"
    fi

    if [ -s "$error_file" ]; then
        fail_self_test "the retry note reached stderr: $(< "$error_file")"
    fi

    unset -f skopeo
}

# self_test_cosign_rejected: the two rejection shapes classified; a missing
# manifest, a DNS failure and an empty output not taken for one.
self_test_cosign_rejected() {
    local key_mismatch='Error: no matching signatures: error verifying bundle:'
    local certificate_bundle='Error: no matching attestations: expected key signature,'
    local missing_manifest='Error: image tag not found: GET https://ghcr.io/v2/x/manifests/stable:'
    local other

    key_mismatch+=' comparing public key PEMs, expected -----BEGIN PUBLIC KEY-----'
    certificate_bundle+=' not certificate'
    missing_manifest+=' MANIFEST_UNKNOWN: manifest unknown'

    if ! cosign_rejected "$key_mismatch"; then
        fail_self_test "key mismatch not classified as a rejection"
    fi

    if ! cosign_rejected "$certificate_bundle"; then
        fail_self_test "certificate-signed bundle not classified as a rejection"
    fi

    for other in "$missing_manifest" 'Error: dial tcp: lookup ghcr.io: no such host' ''; do
        REFUSED=$((REFUSED + 1))

        if cosign_rejected "$other"; then
            fail_self_test "cosign failure $REFUSED taken for a rejection"
        fi
    done
}

# self_test_verifiers: verify_image and negative_controls with cosign, gh and
# sleep as functions. A verified image and a base cosign rejects pass; an image
# cosign does not verify, one without an attestation, a base cosign.pub accepts,
# a base carrying an attestation of this repository and a base cosign could not
# reach are refused.
self_test_verifiers() {
    local image=$REGISTRY/bazzite-mx@$SELF_TEST_IMAGE_DIGEST
    local base=$BASE_REGISTRY/bazzite@$SELF_TEST_BASE_DIGEST
    local rejection='Error: no matching signatures: error verifying bundle'
    local cosign_error="" gh_status=0 output

    cosign() {
        if [ -n "$cosign_error" ]; then
            echo "$cosign_error" >&2
            return 1
        fi
    }
    gh() {
        return "$gh_status"
    }
    sleep() {
        :
    }

    if ! verify_image "$image" > /dev/null; then
        fail_self_test "an image cosign and gh verify refused"
    fi

    REFUSED=$((REFUSED + 1))
    cosign_error=$rejection

    if verify_image "$image" > /dev/null 2>&1; then
        fail_self_test "an image cosign does not verify accepted"
    fi

    REFUSED=$((REFUSED + 1))
    cosign_error=""
    gh_status=1

    if verify_image "$image" > /dev/null 2>&1; then
        fail_self_test "an image without an attestation accepted"
    fi

    cosign_error=$rejection

    if ! negative_controls "$base" > /dev/null; then
        fail_self_test "a base cosign and gh reject failed the negative controls"
    fi

    REFUSED=$((REFUSED + 1))
    gh_status=0

    if negative_controls "$base" > /dev/null 2>&1; then
        fail_self_test "a base carrying an attestation of $REPO passed the negative controls"
    fi

    gh_status=1

    REFUSED=$((REFUSED + 1))
    cosign_error=""

    if output=$(negative_controls "$base" 2>&1) \
        || ! grep -q 'accepted the signature' <<< "$output"; then
        fail_self_test "a base cosign.pub accepts not refused as such: ${output//$'\n'/ }"
    fi

    REFUSED=$((REFUSED + 1))
    cosign_error='Error: dial tcp: lookup ghcr.io: no such host'
    cosign_error+=$'\nerror during command execution: dial tcp'

    if output=$(negative_controls "$base" 2>&1); then
        fail_self_test "a negative control cosign could not run passed"
    fi

    if [ "$(grep -c '' <<< "$output")" -ne 1 ]; then
        fail_self_test "an inconclusive control not folded into one line: ${output//$'\n'/ }"
    fi

    unset -f cosign gh sleep
}

# self_test_copy_tag: copy_tag with skopeo and sleep as functions: a copy skopeo
# wrote passes, one it failed three times is refused.
self_test_copy_tag() {
    skopeo() {
        :
    }
    sleep() {
        :
    }

    if ! copy_tag bazzite-mx "$SELF_TEST_IMAGE_DIGEST" "$SELF_TEST_TAG" > /dev/null; then
        fail_self_test "a copy skopeo wrote refused"
    fi

    skopeo() {
        echo 'FATA[0000] writing manifest: received unexpected HTTP status: 502' >&2
        return 1
    }
    REFUSED=$((REFUSED + 1))

    if copy_tag bazzite-mx "$SELF_TEST_IMAGE_DIGEST" "$SELF_TEST_TAG" > /dev/null 2>&1; then
        fail_self_test "a copy skopeo failed reported as tagged"
    fi

    unset -f skopeo sleep
}

# self_test_base_refused <version job digest> <build digest> <manifest json>:
# one disagreeing set of bases refused by check_base.
self_test_base_refused() {
    local version_job_digest=$1
    local build_digest=$2
    local manifest_json=$3

    REFUSED=$((REFUSED + 1))

    if check_base bazzite "$version_job_digest" ghcr.io/ublue-os/bazzite "$build_digest" \
        "$manifest_json" > /dev/null 2>&1; then
        fail_self_test "disagreeing bases $REFUSED accepted"
    fi
}

# self_test_check_base: three matching readings accepted; a build on another
# base and a manifest labelled with another base refused.
self_test_check_base() {
    local relabelled

    if ! check_base bazzite "$SELF_TEST_BASE_DIGEST" ghcr.io/ublue-os/bazzite \
        "$SELF_TEST_BASE_DIGEST" "$SELF_TEST_MANIFEST" > /dev/null; then
        fail_self_test "three matching bases refused"
    fi

    self_test_base_refused "$SELF_TEST_BASE_DIGEST" "$SELF_TEST_OTHER_DIGEST" "$SELF_TEST_MANIFEST"

    relabelled=$(jq -c --arg digest "$SELF_TEST_OTHER_DIGEST" \
        '.Labels["org.opencontainers.image.base.digest"] = $digest' <<< "$SELF_TEST_MANIFEST")
    self_test_base_refused "$SELF_TEST_BASE_DIGEST" "$SELF_TEST_BASE_DIGEST" "$relabelled"
}

# self_test_base_set_refused <good env> <--base options>...: one set of --base
# options refused by release before any registry call, and for the --base
# itself.
self_test_base_set_refused() {
    local good=$1
    shift
    local output

    REFUSED=$((REFUSED + 1))

    if output=$(release --release-tag "$SELF_TEST_TAG" --revision "$SELF_TEST_REVISION" \
        "$good" "$good" "$good" "$@" 2>&1); then
        fail_self_test "--base set $REFUSED accepted"
    fi

    if ! grep -q -- '--base' <<< "$output"; then
        fail_self_test "--base set $REFUSED refused for another reason: $output"
    fi
}

# self_test_release_arguments <good>: a missing, incomplete, malformed or
# unknown --base set, three env files of one flavour and one env file short
# refused before any registry call.
self_test_release_arguments() {
    local good=$1
    local base=$SELF_TEST_BASE_DIGEST
    local expected_count output

    self_test_base_set_refused "$good"
    self_test_base_set_refused "$good" --base "bazzite=$base"
    self_test_base_set_refused "$good" --base bazzite=sha256:short \
        --base "bazzite-nvidia-open=$base" --base "bazzite-nvidia=$base"
    self_test_base_set_refused "$good" --base "bazzite-deck=$base" \
        --base "bazzite-nvidia-open=$base" --base "bazzite-nvidia=$base"

    REFUSED=$((REFUSED + 1))

    if output=$(release --release-tag "$SELF_TEST_TAG" --revision "$SELF_TEST_REVISION" \
        --base "bazzite=$base" --base "bazzite-nvidia-open=$base" --base "bazzite-nvidia=$base" \
        "$good" "$good" "$good" 2>&1); then
        fail_self_test "three env files of one flavour accepted"
    fi

    if ! grep -q 'given twice, already in' <<< "$output"; then
        fail_self_test "the repeated flavour refused for another reason: $output"
    fi

    expected_count=$(wc -w <<< "$PACKAGES")
    REFUSED=$((REFUSED + 1))

    if output=$(release --release-tag "$SELF_TEST_TAG" --revision "$SELF_TEST_REVISION" \
        "$good" "$good" 2>&1); then
        fail_self_test "two env files accepted for $expected_count flavours"
    fi

    if ! grep -q "expected $expected_count env files" <<< "$output"; then
        fail_self_test "the env-file count is not PACKAGES': $output"
    fi
}

# self_test_stub_registry <calls file>: the registry functions replaced for the
# rest of the process. The manifest is the fixture's with the title and the base
# of the image asked for; every base passes the negative controls; verify_image
# refuses the image STUB_REFUSED names; every tag is free; a copy is one
# `<image>:<tag>` line in the calls file. STUB_FAILING names a stub that fails
# instead: negative_controls, tag_state or copy_tag:<tag>.
self_test_stub_registry() {
    local calls=$1

    inspect_ref() {
        local name=${1#"${REGISTRY}/"}

        name=${name%%[@:]*}
        jq -c --arg name "$name" --arg base "${BASE_REGISTRY}/${name/bazzite-mx/bazzite}:stable" \
            '.Labels["org.opencontainers.image.title"] = $name
             | .Labels["org.opencontainers.image.base.name"] = $base' <<< "$SELF_TEST_MANIFEST"
    }
    negative_controls() {
        if [ "${STUB_FAILING:-}" = negative_controls ]; then
            return 1
        fi
    }
    verify_image() {
        if [ "$1" = "${REGISTRY}/${STUB_REFUSED:-}@${SELF_TEST_IMAGE_DIGEST}" ]; then
            return 1
        fi
    }
    tag_state() {
        if [ "${STUB_FAILING:-}" = tag_state ]; then
            return 1
        fi

        echo free
    }
    copy_tag() {
        if [ "${STUB_FAILING:-}" = "copy_tag:$3" ]; then
            return 1
        fi

        echo "$1:$3" >> "$calls"
    }
}

# self_test_stubbed_promotion <dir>: release and promote on the stubbed
# registry, the copies each makes onto :<tag> and :stable in their order, and
# the refusals that stop each.
self_test_stubbed_promotion() {
    local dir=$1
    local calls=$dir/calls
    local base=$SELF_TEST_BASE_DIGEST
    local flavour last_tag_copy first_stable_copy output failing
    local arguments=(--release-tag "$SELF_TEST_TAG" --revision "$SELF_TEST_REVISION"
        --base "bazzite=$base" --base "bazzite-nvidia-open=$base" --base "bazzite-nvidia=$base"
        "$dir/bazzite.env" "$dir/bazzite-nvidia-open.env" "$dir/bazzite-nvidia.env")

    for flavour in $FLAVOURS; do
        self_test_write_env "$dir/$flavour.env" "$flavour"
    done

    self_test_stub_registry "$calls"

    # Subshells: release exits on a refusal.
    : > "$calls"

    if ! (release "${arguments[@]}" --promote) > /dev/null; then
        fail_self_test "the stubbed release refused three good images"
    fi

    if [ "$(grep -c ':stable$' "$calls")" -ne 3 ]; then
        fail_self_test "expected 3 promotions, got: $(tr '\n' ' ' < "$calls")"
    fi

    last_tag_copy=$(grep -n ":${SELF_TEST_TAG}\$" "$calls" | tail -n1 | cut -d: -f1 || true)
    first_stable_copy=$(grep -n ':stable$' "$calls" | head -n1 | cut -d: -f1 || true)

    if [ -z "$last_tag_copy" ] || [ -z "$first_stable_copy" ]; then
        fail_self_test "a :<tag> or a :stable copy is missing: $(tr '\n' ' ' < "$calls")"
    fi

    if [ "$last_tag_copy" -ge "$first_stable_copy" ]; then
        fail_self_test "a :stable copy preceded a :<tag> copy: $(tr '\n' ' ' < "$calls")"
    fi

    : > "$calls"

    if ! (release "${arguments[@]}") > /dev/null; then
        fail_self_test "the stubbed release without --promote refused three good images"
    fi

    if grep -q ':stable$' "$calls"; then
        fail_self_test ":stable moved without --promote: $(tr '\n' ' ' < "$calls")"
    fi

    REFUSED=$((REFUSED + 1))
    : > "$calls"

    if (STUB_REFUSED=bazzite-mx-nvidia-open release "${arguments[@]}" --promote) \
        > /dev/null 2>&1; then
        fail_self_test "a refused second image did not stop the release"
    fi

    if grep -q ':stable$' "$calls"; then
        fail_self_test ":stable moved with the second image refused: $(tr '\n' ' ' < "$calls")"
    fi

    : > "$calls"

    if ! (promote --release-tag "$SELF_TEST_TAG") > /dev/null; then
        fail_self_test "the stubbed promote refused three good images"
    fi

    if [ "$(grep -c ':stable$' "$calls")" -ne 3 ]; then
        fail_self_test "expected 3 promotions by promote, got: $(tr '\n' ' ' < "$calls")"
    fi

    REFUSED=$((REFUSED + 1))
    : > "$calls"

    if (STUB_REFUSED=bazzite-mx-nvidia-open promote --release-tag "$SELF_TEST_TAG") \
        > /dev/null 2>&1; then
        fail_self_test "a refused second image did not stop promote"
    fi

    if grep -q ':stable$' "$calls"; then
        fail_self_test "promote moved :stable with the second image refused:" \
            "$(tr '\n' ' ' < "$calls")"
    fi

    for failing in negative_controls tag_state "copy_tag:$SELF_TEST_TAG" copy_tag:stable; do
        REFUSED=$((REFUSED + 1))

        if (STUB_FAILING=$failing release "${arguments[@]}" --promote) > /dev/null 2>&1; then
            fail_self_test "the release went on past a failing $failing"
        fi
    done

    REFUSED=$((REFUSED + 1))

    if (STUB_FAILING=negative_controls promote --release-tag "$SELF_TEST_TAG") \
        > /dev/null 2>&1; then
        fail_self_test "promote went on past failing negative controls"
    fi

    REFUSED=$((REFUSED + 1))

    if (release "${arguments[@]}" --base "bazzite=$SELF_TEST_OTHER_DIGEST") > /dev/null 2>&1; then
        fail_self_test "the release went on past disagreeing bases"
    fi

    # Known-bad: the caller's own line followed check_labels' reason.
    REFUSED=$((REFUSED + 1))

    if output=$( (release "${arguments[@]}" --revision "$SELF_TEST_WRONG_REVISION") 2>&1 \
        > /dev/null); then
        fail_self_test "the stubbed release accepted a wrong revision"
    fi

    if [ "$(grep -c '' <<< "$output")" -ne 1 ]; then
        fail_self_test "a refused label not one line in release: ${output//$'\n'/ }"
    fi

    REFUSED=$((REFUSED + 1))

    if output=$( (promote --release-tag 44.20260902) 2>&1 > /dev/null); then
        fail_self_test "the stubbed promote accepted images of another tag"
    fi

    if [ "$(grep -c '' <<< "$output")" -ne 1 ]; then
        fail_self_test "a refused label not one line in promote: ${output//$'\n'/ }"
    fi

    REFUSED=$((REFUSED + 1))

    if output=$(promote --release-tag stable 2>&1); then
        fail_self_test "promote accepted the malformed tag 'stable'"
    fi

    if ! grep -q -- '--release-tag must be' <<< "$output"; then
        fail_self_test "promote refused 'stable' for another reason: $output"
    fi
}

self_test() {
    local dir good

    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    good=$dir/good.env
    self_test_write_manifest

    self_test_write_env "$good" bazzite

    self_test_labels
    self_test_base_of
    self_test_classify_tag
    self_test_inspect_retry_note
    self_test_cosign_rejected
    self_test_verifiers
    self_test_copy_tag
    self_test_check_base
    self_test_release_arguments "$good"
    self_test_stubbed_promotion "$dir"

    echo "self-test ok: 2 manifests accepted, 1 base read, 3 bases matched," \
        "2 tag states classified, 2 cosign rejections classified," \
        "1 image verified, 1 base refused by both verifiers, 1 tag copied," \
        "promotion after the last verification, $REFUSED bad inputs refused"
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
    promote)
        shift
        promote "$@"
        ;;
    *)
        exit_with_error "usage: gate-release.sh release --release-tag <tag> --revision <sha>" \
            "[--promote] --base <flavour>=<digest>... <env-file>... |" \
            "promote --release-tag <tag> | --self-test"
        ;;
esac
