#!/usr/bin/env bash
# Resolve a base image to the coordinates every build consumes: the digest the
# build pins to, the version the release title quotes, the kernel the akmods
# carrier is picked by, and the image name the flavour maps to. One owner for the schema, used by CI and the pre-flight.
#
#   resolve-base.sh <flavour>            flavour: bazzite | bazzite-nvidia-open
#   resolve-base.sh --from-json <file> <flavour>   parse a saved `skopeo inspect`
#   resolve-base.sh --self-test          prove the fail-closed paths
#
# Prints KEY=value lines (shell-sourceable) and appends them to $GITHUB_OUTPUT
# when set. Every value is required: an empty label is a failure, never a
# default (verification.md: blank-where-value-expected is failure).
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

TAG=stable

inspect_remote() {
    skopeo inspect --retry-times 3 --no-tags "docker://${BASE_REGISTRY}/$1:${TAG}"
}

resolve() {
    local flavour=$1 json=$2
    local digest kernel version fedora
    local image_name
    image_name=$(image_of "$flavour") || return 1
    digest=$(jq -r '.Digest // empty' <<< "$json")
    kernel=$(jq -r '.Labels["ostree.linux"] // empty' <<< "$json")
    version=$(jq -r '.Labels["org.opencontainers.image.version"] // empty' <<< "$json")
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
        err "no digest for $flavour: '$digest'"
        return 1
    }
    [[ "$kernel" =~ ^[0-9]+\.[0-9]+.*\.fc[0-9]+\.x86_64$ ]] || {
        err "no ostree.linux label for $flavour: '$kernel'"
        return 1
    }
    [ -n "$version" ] || {
        err "no org.opencontainers.image.version label for $flavour"
        return 1
    }
    fedora=${kernel##*.fc}
    fedora=${fedora%%.*}
    printf '%s\n' \
        "image_name=${image_name}" \
        "base_name=${BASE_REGISTRY}/${flavour}" \
        "base_image=${BASE_REGISTRY}/${flavour}@${digest}" \
        "base_digest=${digest}" \
        "base_version=${version}" \
        "kernel_version=${kernel}" \
        "fedora_version=${fedora}"
}

# --- the digests --------------------------------------------------------------

# digest_key <flavour>: the output key of a flavour's base digest, snake_case
# as every output.
digest_key() {
    local flavour=$1

    echo "base_digest_${flavour//-/_}"
}

# digests_from <inspect json>...: one keyed digest per flavour, the manifests
# given in FLAVOURS order; status 1 when one of them does not resolve.
digests_from() {
    local flavour coords

    for flavour in $FLAVOURS; do
        if ! coords=$(resolve "$flavour" "$1"); then
            return 1
        fi
        echo "$(digest_key "$flavour")=$(sed -n 's/^base_digest=//p' <<< "$coords")"
        shift
    done
}

# --- the commands -------------------------------------------------------------

# report <flavour> <inspect json>: the coordinates emitted; exits 1 when they
# do not resolve.
report() {
    local flavour=$1
    local manifest=$2
    local coords

    if ! coords=$(resolve "$flavour" "$manifest"); then
        exit 1
    fi

    emit "$coords"
}

# report_digests: the three bases inspected, their keyed digests emitted.
report_digests() {
    local flavour digests
    local -a manifests=()

    for flavour in $FLAVOURS; do
        manifests+=("$(inspect_remote "$flavour")")
    done

    if ! digests=$(digests_from "${manifests[@]}"); then
        exit 1
    fi

    emit "$digests"
}

# --- self-test ----------------------------------------------------------------

SELF_TEST_DIGEST=sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76

# self_test_manifest: a complete `skopeo inspect` of a Fedora 44 base.
self_test_manifest() {
    local labels='{"ostree.linux":"%s","org.opencontainers.image.version":"%s"}'

    printf "{\"Digest\":\"%s\",\"Labels\":$labels}" \
        "$SELF_TEST_DIGEST" 7.2.1-ogc4.1.fc44.x86_64 44.20260902
}

# self_test_resolve <manifest>: the three flavours resolved, the Fedora
# release read from the kernel and the base image pinned to the digest.
self_test_resolve() {
    local manifest=$1
    local bazzite nvidia_open nvidia

    if ! bazzite=$(resolve bazzite "$manifest"); then
        fail_self_test "known-good input did not resolve"
    fi
    nvidia_open=$(resolve bazzite-nvidia-open "$manifest" || true)
    nvidia=$(resolve bazzite-nvidia "$manifest" || true)

    if ! grep -qx 'fedora_version=44' <<< "$bazzite"; then
        fail_self_test "fedora_version not read from the kernel"
    fi
    if ! grep -qx 'image_name=bazzite-mx-nvidia-open' <<< "$nvidia_open"; then
        fail_self_test "image_name not derived"
    fi
    if ! grep -qx 'image_name=bazzite-mx-nvidia' <<< "$nvidia"; then
        fail_self_test "the closed flavour's image_name not derived"
    fi
    if ! grep -qx "base_image=ghcr.io/ublue-os/bazzite@$SELF_TEST_DIGEST" <<< "$bazzite"; then
        fail_self_test "base_image not pinned to the digest"
    fi
}

# self_test_bad_inputs <manifest>: a manifest without the kernel label, one
# without the version label, one with a short digest and an empty one refused;
# an unknown flavour refused.
self_test_bad_inputs() {
    local manifest=$1
    local bad

    for bad in \
        "$(jq -c 'del(.Labels["ostree.linux"])' <<< "$manifest")" \
        "$(jq -c 'del(.Labels["org.opencontainers.image.version"])' <<< "$manifest")" \
        "$(jq -c '.Digest = "sha256:short"' <<< "$manifest")" \
        '{}'; do
        REFUSED=$((REFUSED + 1))
        if resolve bazzite "$bad" > /dev/null 2>&1; then
            fail_self_test "known-bad input $REFUSED resolved"
        fi
    done

    REFUSED=$((REFUSED + 1))
    if resolve bazzite-nvidia-closed "$manifest" > /dev/null 2>&1; then
        fail_self_test "unknown flavour resolved"
    fi
}

# self_test_digests <manifest>: the output key snake_case, one keyed digest per
# flavour, and a flavour without a digest refused.
self_test_digests() {
    local manifest=$1
    local expected

    if [ "$(digest_key bazzite-nvidia-open)" != base_digest_bazzite_nvidia_open ]; then
        fail_self_test "the output key of a flavour is not snake_case"
    fi

    expected=$(printf '%s\n' \
        "base_digest_bazzite=$SELF_TEST_DIGEST" \
        "base_digest_bazzite_nvidia_open=$SELF_TEST_DIGEST" \
        "base_digest_bazzite_nvidia=$SELF_TEST_DIGEST")
    if [ "$(digests_from "$manifest" "$manifest" "$manifest")" != "$expected" ]; then
        fail_self_test "--digests did not print one keyed digest per flavour"
    fi

    REFUSED=$((REFUSED + 1))
    if digests_from "$manifest" "$manifest" '{}' > /dev/null 2>&1; then
        fail_self_test "--digests accepted a flavour without a digest"
    fi
}

self_test() {
    local manifest

    manifest=$(self_test_manifest)

    self_test_resolve "$manifest"
    self_test_bad_inputs "$manifest"
    self_test_digests "$manifest"

    echo "self-test ok: 3 flavours resolved, 3 digests keyed, $REFUSED bad inputs refused"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    --from-json)
        if [ $# -ne 3 ]; then
            exit_with_error "usage: --from-json <file> <flavour>"
        fi
        report "$3" "$(cat "$2")"
        ;;
    --digests)
        report_digests
        ;;
    "")
        exit_with_error "usage: resolve-base.sh <flavour> | --digests" \
            "| --from-json <file> <flavour> | --self-test"
        ;;
    *)
        report "$1" "$(inspect_remote "$1")"
        ;;
esac
