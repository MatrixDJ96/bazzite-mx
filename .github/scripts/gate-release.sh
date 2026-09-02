#!/usr/bin/env bash
# The gate between a pushed :staging image and a tag a host may pull. Images are
# named by digest, never by a :staging tag a later run reuses. Every verifier is
# first shown to FAIL on the flavour's own base, so none of them is a no-op.
#
#   gate-release.sh release --release-tag <tag> --revision <sha> [--promote] \
#       --base <flavour>=<digest>... <env-file>...
#       env-file: image_name, digest, base_name, base_digest, from the build
#                 job; --base: the base digest the version job resolved, one
#                 per flavour. Verifies each image, requires the three base
#                 readings (version job, build, manifest label) to agree, and
#                 copies its digest onto :<tag>, refused when :<tag> already
#                 points elsewhere, and with --promote onto :stable.
#   gate-release.sh promote --release-tag <tag>
#       re-verify the images :<tag> points at, then move :stable onto them
#   gate-release.sh --self-test
#
# Needs skopeo, cosign, gh (GH_TOKEN), a docker login to ghcr.io (cosign and
# gh read the docker credentials) and cosign.pub in the working directory.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

VENDOR=matrixdj96
COSIGN_PUB=${COSIGN_PUB:-cosign.pub}

retry() {
    local n
    for n in 1 2 3; do
        "$@" && return 0
        [ "$n" -eq 3 ] && return 1
        sleep 15
    done
}

# An empty revision skips the revision check (promote mode).
check_labels() {
    local json=$1 name=$2 tag=$3 revision=$4
    local title vendor version rev
    title=$(jq -r '.Labels["org.opencontainers.image.title"] // empty' <<< "$json")
    vendor=$(jq -r '.Labels["org.opencontainers.image.vendor"] // empty' <<< "$json")
    version=$(jq -r '.Labels["org.opencontainers.image.version"] // empty' <<< "$json")
    rev=$(jq -r '.Labels["org.opencontainers.image.revision"] // empty' <<< "$json")
    [ "$title" = "$name" ] || {
        err "title is '$title', expected '$name'"
        return 1
    }
    [ "$vendor" = "$VENDOR" ] || {
        err "vendor is '$vendor', expected '$VENDOR'"
        return 1
    }
    [ "$version" = "$tag" ] || {
        err "version is '$version', expected '$tag'"
        return 1
    }
    if [ -n "$revision" ]; then
        [ "$rev" = "$revision" ] || {
            err "revision is '$rev', expected '$revision'"
            return 1
        }
    fi
}

# Prints `free` or `same`, and fails on anything else: a release tag is never
# re-pointed and an unreadable registry is never taken for an empty one.
classify_tag() {
    local status=$1 stderr=$2 got=$3 wanted=$4
    if [ "$status" -eq 0 ]; then
        [ "$got" = "$wanted" ] || {
            err "tag exists and points at $got, not $wanted: a release tag never moves"
            return 1
        }
        echo same
        return 0
    fi
    if grep -qiE 'manifest unknown|not found|MANIFEST_UNKNOWN|NAME_UNKNOWN' <<< "$stderr"; then
        echo free
        return 0
    fi
    err "could not tell whether the tag exists: $stderr"
    return 1
}

inspect_ref() {
    skopeo inspect --retry-times 3 --no-tags "docker://$1"
}

tag_state() {
    local image=$1 tag=$2 digest=$3 out errs status=0 got=""
    out=$(skopeo inspect --retry-times 3 --no-tags "docker://${REGISTRY}/${image}:${tag}" 2> "$TMP/inspect.err") || status=$?
    errs=$(cat "$TMP/inspect.err")
    [ "$status" -eq 0 ] && got=$(jq -r '.Digest' <<< "$out")
    classify_tag "$status" "$errs" "$got" "$digest"
}

# True only when cosign refused the signing material, never on a transport
# error. The second shape comes from an image whose provenance bundle, signed
# with a certificate, cosign reads before the .sig (docs/gotchas.md).
cosign_rejected() {
    grep -qE 'no matching signatures|no matching attestations: expected key signature' <<< "$1"
}

# The base the manifest was built from, read off the labels image-labels.sh
# wrote; refused when either label is missing or malformed.
base_of() {
    local json=$1 name digest
    name=$(jq -r '.Labels["org.opencontainers.image.base.name"] // empty' <<< "$json")
    digest=$(jq -r '.Labels["org.opencontainers.image.base.digest"] // empty' <<< "$json")
    [[ "$name" =~ ^ghcr\.io/ublue-os/[a-z-]+:stable$ && "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
        err "no base labels on the manifest: name '$name', digest '$digest'"
        return 1
    }
    echo "${name%:stable}@${digest}"
}

# The base the version job resolved, the one the build job wrote in its env
# file and the one the manifest's label names must be the same digest: a base
# that moved between the jobs of one run, or a build that resolved on its own,
# is refused with the three readings side by side.
check_base() {
    local flavour=$1 expected=$2 name=$3 digest=$4 json=$5 labelled
    [[ "$expected" =~ ^sha256:[0-9a-f]{64}$ ]] || {
        err "the version job's base digest for $flavour is malformed: '$expected'"
        return 1
    }
    labelled=$(base_of "$json") || return 1
    [ "$digest" = "$expected" ] && [ "$labelled" = "${name}@${expected}" ] || {
        err "base digests disagree for $flavour: version job $expected, build $digest, manifest label ${labelled#*@}"
        return 1
    }
    echo "base ok: ${name}@${expected} (version job, build and manifest label agree)"
}

# The flavour's own base is signed by ublue-os, so our key and our attestation
# lookup must both reject it. Only a signature-class rejection counts: a
# network error also exits non-zero and would pass a control that saw nothing.
negative_controls() {
    local ref=$1 out
    if out=$(cosign verify --key "$COSIGN_PUB" "$ref" 2>&1 > /dev/null); then
        err "negative control: cosign.pub accepted the signature of $ref"
        return 1
    fi
    cosign_rejected "$out" || {
        err "negative control inconclusive: cosign failed on $ref for another reason: $out"
        return 1
    }
    if gh attestation verify "oci://$ref" --repo "$REPO" > /dev/null 2>&1; then
        err "negative control: an attestation of $REPO was found on $ref"
        return 1
    fi
    echo "negative controls ok: $ref rejected by cosign.pub and by the attestation lookup"
}

verify_image() {
    local ref=$1
    retry cosign verify --key "$COSIGN_PUB" "$ref" > /dev/null || {
        err "cosign verify failed on $ref"
        return 1
    }
    retry gh attestation verify "oci://$ref" --repo "$REPO" > /dev/null || {
        err "gh attestation verify failed on $ref"
        return 1
    }
    echo "verified: $ref (cosign.pub, attestation of $REPO)"
}

copy_tag() {
    local image=$1 digest=$2 tag=$3
    retry skopeo copy --preserve-digests \
        "docker://${REGISTRY}/${image}@${digest}" "docker://${REGISTRY}/${image}:${tag}" > /dev/null \
        || {
            err "skopeo copy to ${image}:${tag} failed"
            return 1
        }
    echo "tagged: ${image}:${tag} -> ${digest}"
}

release() {
    local tag="" revision="" promote=no files=() json state
    local -A bases=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --release-tag)
                tag=$2
                shift 2
                ;;
            --revision)
                revision=$2
                shift 2
                ;;
            --promote)
                promote=yes
                shift
                ;;
            --base)
                [[ "$2" =~ ^([a-z-]+)=(sha256:[0-9a-f]{64})$ ]] || fail "--base must be <flavour>=sha256:<64 hex>: '$2'"
                [ -z "${bases[${BASH_REMATCH[1]}]:-}" ] || fail "--base given twice for ${BASH_REMATCH[1]}"
                bases[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
                shift 2
                ;;
            -*) fail "unknown option '$1'" ;;
            *)
                files+=("$1")
                shift
                ;;
        esac
    done
    [[ "$tag" =~ $TAG_SHAPE ]] || fail "--release-tag must be <fedora>.<yyyymmdd>[.N]: '$tag'"
    [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "--revision must be a full commit sha: '$revision'"
    local expected file flavour
    local -A seen=()
    expected=$(wc -w <<< "$PACKAGES")
    [ "${#files[@]}" -eq "$expected" ] || fail "expected $expected env files (one per flavour), got ${#files[@]}"
    [ "${#bases[@]}" -eq "$expected" ] || fail "expected $expected --base <flavour>=<digest> (the version job's, one per flavour), got ${#bases[@]}"
    [ -f "$COSIGN_PUB" ] || fail "$COSIGN_PUB missing: run from the repository root"
    for file in "${files[@]}"; do
        read_env "$file" || exit 1
        flavour=${base_name#"${BASE_REGISTRY}/"}
        [ -n "${bases[$flavour]:-}" ] || fail "$file: no --base for ${flavour}: the version job resolved ${!bases[*]}"
        [ -z "${seen[$flavour]:-}" ] || fail "$file: flavour ${flavour} given twice, already in ${seen[$flavour]}"
        seen[$flavour]=$file
    done
    local -a verified_images=() verified_digests=()
    for file in "${files[@]}"; do
        read_env "$file" || exit 1
        flavour=${base_name#"${BASE_REGISTRY}/"}
        echo "== ${image_name}@${digest} (from $file)"
        json=$(inspect_ref "${REGISTRY}/${image_name}@${digest}") || fail "cannot inspect ${image_name}@${digest}"
        check_labels "$json" "$image_name" "$tag" "$revision" || fail "labels of ${image_name}@${digest} refused"
        echo "labels ok: title ${image_name}, version ${tag}, revision ${revision:0:7}"
        check_base "$flavour" "${bases[$flavour]}" "$base_name" "$base_digest" "$json" || exit 1
        negative_controls "${base_name}@${base_digest}" || exit 1
        verify_image "${REGISTRY}/${image_name}@${digest}" || exit 1
        state=$(tag_state "$image_name" "$tag" "$digest") || exit 1
        case "$state" in
            same) echo "tag ${image_name}:${tag} already points at ${digest}" ;;
            free) copy_tag "$image_name" "$digest" "$tag" || exit 1 ;;
        esac
        verified_images+=("$image_name")
        verified_digests+=("$digest")
    done
    # :stable moves only once every image has passed: a flavour refused above
    # leaves no sibling promoted on its own (docs/workflow.md, the gate job).
    if [ "$promote" = yes ]; then
        local i
        for i in "${!verified_images[@]}"; do
            copy_tag "${verified_images[$i]}" "${verified_digests[$i]}" stable || exit 1
        done
    else
        echo "promotion not requested (:stable untouched)"
    fi
    echo "gate ok: ${tag} on ${#files[@]} images, promote=${promote}"
}

promote() {
    local tag="" pkg json digest base
    while [ $# -gt 0 ]; do
        case "$1" in
            --release-tag)
                tag=$2
                shift 2
                ;;
            *) fail "unknown option '$1'" ;;
        esac
    done
    [[ "$tag" =~ $TAG_SHAPE ]] || fail "--release-tag must be <fedora>.<yyyymmdd>[.N]: '$tag'"
    [ -f "$COSIGN_PUB" ] || fail "$COSIGN_PUB missing: run from the repository root"
    for pkg in $PACKAGES; do
        echo "== ${pkg}:${tag}"
        json=$(inspect_ref "${REGISTRY}/${pkg}:${tag}") || fail "cannot inspect ${pkg}:${tag}"
        digest=$(jq -r '.Digest' <<< "$json")
        [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "no digest for ${pkg}:${tag}"
        check_labels "$json" "$pkg" "$tag" "" || fail "labels of ${pkg}:${tag} refused"
        base=$(base_of "$json") || exit 1
        negative_controls "$base" || exit 1
        verify_image "${REGISTRY}/${pkg}@${digest}" || exit 1
        copy_tag "$pkg" "$digest" stable || exit 1
    done
    echo "promote ok: :stable -> ${tag} on $(wc -w <<< "$PACKAGES") images"
}

self_test() {
    local dir good n=0 json out
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    good=$dir/good.env
    printf '%s\n' \
        image_name=bazzite-mx \
        digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        base_name=ghcr.io/ublue-os/bazzite \
        base_digest=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76 > "$good"
    read_env "$good" || fail "self-test: known-good env file refused"
    [ "$image_name" = bazzite-mx ] || fail "self-test: image_name not read"
    sed 's/^digest=.*/digest=sha256:short/' "$good" > "$dir/bad1.env"
    sed 's/^image_name=.*/image_name=bazzite/' "$good" > "$dir/bad2.env"
    for bad in "$dir/bad1.env" "$dir/bad2.env" "$dir/absent.env"; do
        n=$((n + 1))
        if read_env "$bad" > /dev/null 2>&1; then
            fail "self-test: known-bad env file $n accepted"
        fi
    done
    json='{"Digest":"sha256:aaaa","Labels":{"org.opencontainers.image.title":"bazzite-mx","org.opencontainers.image.vendor":"matrixdj96","org.opencontainers.image.version":"44.20260903","org.opencontainers.image.revision":"8cfea1732f154089321597d3c52084db3e9dd8ce","org.opencontainers.image.base.name":"ghcr.io/ublue-os/bazzite:stable","org.opencontainers.image.base.digest":"sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76"}}'
    check_labels "$json" bazzite-mx 44.20260903 8cfea1732f154089321597d3c52084db3e9dd8ce || fail "self-test: matching labels refused"
    [ "$(base_of "$json")" = ghcr.io/ublue-os/bazzite@sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76 ] \
        || fail "self-test: base not read from the labels"
    for bad in "$(jq -c 'del(.Labels["org.opencontainers.image.base.digest"])' <<< "$json")" \
        "$(jq -c '.Labels["org.opencontainers.image.base.name"] = "docker.io/library/fedora:44"' <<< "$json")"; do
        n=$((n + 1))
        if base_of "$bad" > /dev/null 2>&1; then
            fail "self-test: manifest without a usable base $n accepted"
        fi
    done
    check_labels "$json" bazzite-mx 44.20260903 "" || fail "self-test: labels refused with the revision check off"
    for bad in \
        "$(jq -c '.Labels["org.opencontainers.image.version"] = "44.20260902"' <<< "$json")|bazzite-mx|8cfea1732f154089321597d3c52084db3e9dd8ce" \
        "$json|bazzite-mx|0000000000000000000000000000000000000000" \
        "$(jq -c '.Labels["org.opencontainers.image.title"] = "Bazzite"' <<< "$json")|bazzite-mx|8cfea1732f154089321597d3c52084db3e9dd8ce" \
        "$(jq -c '.Labels["org.opencontainers.image.vendor"] = "ublue-os"' <<< "$json")|bazzite-mx|8cfea1732f154089321597d3c52084db3e9dd8ce"; do
        n=$((n + 1))
        IFS='|' read -r j name rev <<< "$bad"
        if check_labels "$j" "$name" 44.20260903 "$rev" > /dev/null 2>&1; then
            fail "self-test: known-bad manifest $n accepted"
        fi
    done
    [ "$(classify_tag 1 'reading manifest 44.20260903 in ghcr.io/x: manifest unknown' '' sha256:aaaa)" = free ] \
        || fail "self-test: missing tag not classified free"
    [ "$(classify_tag 0 '' sha256:aaaa sha256:aaaa)" = same ] || fail "self-test: same digest not classified same"
    for bad in "0||sha256:bbbb|sha256:aaaa" "1|unauthorized: authentication required||sha256:aaaa"; do
        n=$((n + 1))
        IFS='|' read -r status stderr got wanted <<< "$bad"
        if classify_tag "$status" "$stderr" "$got" "$wanted" > /dev/null 2>&1; then
            fail "self-test: tag state $n accepted"
        fi
    done
    cosign_rejected 'Error: no matching signatures: error verifying bundle: comparing public key PEMs, expected -----BEGIN PUBLIC KEY-----' \
        || fail "self-test: key mismatch not classified as a rejection"
    cosign_rejected 'Error: no matching attestations: expected key signature, not certificate' \
        || fail "self-test: certificate-signed bundle not classified as a rejection"
    for bad in 'Error: image tag not found: GET https://ghcr.io/v2/x/manifests/stable: MANIFEST_UNKNOWN: manifest unknown' \
        'Error: dial tcp: lookup ghcr.io: no such host' ''; do
        n=$((n + 1))
        if cosign_rejected "$bad"; then
            fail "self-test: cosign failure $n taken for a rejection"
        fi
    done
    # The three bases must agree: the version job's, the build's env file and
    # the manifest's label.
    check_base bazzite sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76 \
        ghcr.io/ublue-os/bazzite sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76 "$json" > /dev/null \
        || fail "self-test: three matching bases refused"
    for bad in \
        "bazzite|sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76|ghcr.io/ublue-os/bazzite|sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc|$json" \
        "bazzite|sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76|ghcr.io/ublue-os/bazzite|sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76|$(jq -c '.Labels["org.opencontainers.image.base.digest"] = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"' <<< "$json")" \
        "bazzite|sha256:short|ghcr.io/ublue-os/bazzite|sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76|$json"; do
        n=$((n + 1))
        IFS='|' read -r flavour expected name digest j <<< "$bad"
        if check_base "$flavour" "$expected" "$name" "$digest" "$j" > /dev/null 2>&1; then
            fail "self-test: disagreeing bases $n accepted"
        fi
    done
    # A missing, repeated or malformed --base is refused before any registry call.
    local three=(--release-tag 44.20260903 --revision 8cfea1732f154089321597d3c52084db3e9dd8ce "$good" "$good" "$good")
    for bad in \
        "" \
        "--base bazzite=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76" \
        "--base bazzite=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76 --base bazzite=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76 --base bazzite-nvidia=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76" \
        "--base bazzite=sha256:short --base bazzite-nvidia-open=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76 --base bazzite-nvidia=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76" \
        "--base bazzite-deck=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76 --base bazzite-nvidia-open=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76 --base bazzite-nvidia=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76"; do
        n=$((n + 1))
        # shellcheck disable=SC2086  # the option list is split on purpose
        if out=$(release "${three[@]}" $bad 2>&1); then
            fail "self-test: --base set $n accepted"
        fi
        grep -q -- '--base' <<< "$out" || fail "self-test: --base set $n refused for another reason: $out"
    done
    # Three env files of one flavour are refused before any registry call.
    n=$((n + 1))
    if out=$(release "${three[@]}" --base bazzite=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76 \
        --base bazzite-nvidia-open=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76 \
        --base bazzite-nvidia=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76 2>&1); then
        fail "self-test: three env files of one flavour accepted"
    fi
    grep -q 'given twice, already in' <<< "$out" || fail "self-test: the repeated flavour refused for another reason: $out"
    # One file short is refused before any registry call.
    n=$((n + 1))
    if out=$(release --release-tag 44.20260903 --revision 8cfea1732f154089321597d3c52084db3e9dd8ce "$good" "$good" 2>&1); then
        fail "self-test: two env files accepted for $(wc -w <<< "$PACKAGES") flavours"
    fi
    grep -q "expected $(wc -w <<< "$PACKAGES") env files" <<< "$out" || fail "self-test: the env-file count is not PACKAGES': $out"
    # Promotion on a stubbed registry, last because the stubs replace the
    # registry functions for the rest of the process: every :<tag> copy
    # precedes the first :stable copy, and a second image refused by the
    # verifier leaves :stable untouched on the first.
    local calls=$dir/calls flavour stub_json=$json
    for flavour in $FLAVOURS; do
        printf '%s\n' "image_name=$(image_of "$flavour")" \
            digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
            "base_name=${BASE_REGISTRY}/${flavour}" \
            base_digest=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76 > "$dir/$flavour.env"
    done
    inspect_ref() {
        local name=${1#"${REGISTRY}/"}
        name=${name%@*}
        jq -c --arg name "$name" --arg base "${BASE_REGISTRY}/${name/bazzite-mx/bazzite}:stable" \
            '.Labels["org.opencontainers.image.title"] = $name | .Labels["org.opencontainers.image.base.name"] = $base' <<< "$stub_json"
    }
    negative_controls() { :; }
    verify_image() {
        [ "$1" != "${REGISTRY}/${STUB_REFUSED:-}@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ] || return 1
    }
    tag_state() { echo free; }
    copy_tag() { echo "$1:$3" >> "$calls"; }
    local three_bases=(--base bazzite=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76
        --base bazzite-nvidia-open=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76
        --base bazzite-nvidia=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76)
    # Subshells: release exits on a refusal, and the stubs stay in this process.
    : > "$calls"
    (release --release-tag 44.20260903 --revision 8cfea1732f154089321597d3c52084db3e9dd8ce --promote "${three_bases[@]}" \
        "$dir/bazzite.env" "$dir/bazzite-nvidia-open.env" "$dir/bazzite-nvidia.env") > /dev/null \
        || fail "self-test: the stubbed release refused three good images"
    [ "$(grep -c ':stable$' "$calls")" -eq 3 ] || fail "self-test: expected 3 promotions, got: $(tr '\n' ' ' < "$calls")"
    [ "$(grep -n ':44.20260903$' "$calls" | tail -n1 | cut -d: -f1)" -lt "$(grep -n ':stable$' "$calls" | head -n1 | cut -d: -f1)" ] \
        || fail "self-test: a :stable copy preceded a :<tag> copy: $(tr '\n' ' ' < "$calls")"
    n=$((n + 1))
    : > "$calls"
    if (STUB_REFUSED=bazzite-mx-nvidia-open release --release-tag 44.20260903 --revision 8cfea1732f154089321597d3c52084db3e9dd8ce --promote "${three_bases[@]}" \
        "$dir/bazzite.env" "$dir/bazzite-nvidia-open.env" "$dir/bazzite-nvidia.env") > /dev/null 2>&1; then
        fail "self-test: a refused second image did not stop the release"
    fi
    ! grep -q ':stable$' "$calls" || fail "self-test: :stable moved with the second image refused: $(tr '\n' ' ' < "$calls")"
    echo "self-test ok: 1 env file read, 2 manifests accepted, 1 base read, 3 bases matched, 2 tag states classified, 2 cosign rejections classified, promotion after the last verification, $n bad inputs refused"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
case "${1:-}" in
    --self-test) self_test ;;
    release)
        shift
        release "$@"
        ;;
    promote)
        shift
        promote "$@"
        ;;
    *) fail "usage: gate-release.sh release --release-tag <tag> --revision <sha> [--promote] --base <flavour>=<digest>... <env-file>... | promote --release-tag <tag> | --self-test" ;;
esac
