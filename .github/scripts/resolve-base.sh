#!/usr/bin/env bash
# Resolve a base image to the coordinates every build consumes: the digest the
# build pins to, the version the release title quotes, the kernel the akmods
# carrier is picked by. One owner for the schema, used by CI and the pre-flight.
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
    case "$flavour" in
        bazzite | bazzite-nvidia-open) ;;
        *)
            err "unknown flavour '$flavour' (bazzite | bazzite-nvidia-open)"
            return 1
            ;;
    esac
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
        "base_name=${REGISTRY}/${flavour}" \
        "base_image=${REGISTRY}/${flavour}@${digest}" \
        "base_digest=${digest}" \
        "base_version=${version}" \
        "kernel_version=${kernel}" \
        "fedora_version=${fedora}"
}

report() {
    local out
    out=$(resolve "$@") || exit 1
    emit "$out"
}

# The output key of a flavour's base digest: snake_case, as every output.
digest_key() {
    echo "base_digest_${1//-/_}"
}

# One keyed digest per flavour, from the three manifests in FLAVOURS order:
# the release run's version job reads the bases once, and the gate holds the
# build jobs to that reading.
digests_from() {
    local flavour out
    for flavour in $FLAVOURS; do
        out=$(resolve "$flavour" "$1") || return 1
        echo "$(digest_key "$flavour")=$(sed -n 's/^base_digest=//p' <<< "$out")"
        shift
    done
}

report_digests() {
    local flavour jsons=() out
    for flavour in $FLAVOURS; do
        jsons+=("$(inspect_remote "$flavour")")
    done
    out=$(digests_from "${jsons[@]}") || exit 1
    emit "$out"
}

self_test() {
    local good bad n=0
    good='{"Digest":"sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76","Labels":{"ostree.linux":"7.2.1-ogc4.1.fc44.x86_64","org.opencontainers.image.version":"44.20260902"}}'
    # Known-good input resolves, and the derived Fedora version is right.
    resolve bazzite "$good" | grep -qx 'fedora_version=44' || fail "self-test: known-good input did not resolve"
    resolve bazzite "$good" | grep -qx 'base_image=ghcr.io/ublue-os/bazzite@sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76' \
        || fail "self-test: base_image not pinned to the digest"
    # Every known-bad input must fail: missing kernel label, missing version,
    # malformed digest, unknown flavour.
    for bad in \
        "$(jq -c 'del(.Labels["ostree.linux"])' <<< "$good")" \
        "$(jq -c 'del(.Labels["org.opencontainers.image.version"])' <<< "$good")" \
        "$(jq -c '.Digest = "sha256:short"' <<< "$good")" \
        '{}'; do
        n=$((n + 1))
        if resolve bazzite "$bad" > /dev/null 2>&1; then
            fail "self-test: known-bad input $n resolved"
        fi
    done
    if resolve bazzite-nvidia-closed "$good" > /dev/null 2>&1; then
        fail "self-test: unknown flavour resolved"
    fi
    [ "$(digest_key bazzite-nvidia-open)" = base_digest_bazzite_nvidia_open ] \
        || fail "self-test: the output key of a flavour is not snake_case"
    [ "$(digests_from "$good" "$good" "$good")" = "$(printf 'base_digest_bazzite=%s\nbase_digest_bazzite_nvidia_open=%s\nbase_digest_bazzite_nvidia=%s\n' \
        sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76 sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76 sha256:9556db65991d57a03a7dc18e4ba28a686d8bcdcd6b61235aa69c8267bb22ff76)" ] \
        || fail "self-test: --digests did not print one keyed digest per flavour"
    n=$((n + 1))
    if digests_from "$good" "$good" '{}' > /dev/null 2>&1; then
        fail "self-test: --digests accepted a flavour without a digest"
    fi
    echo "self-test ok: 3 flavours resolved, 3 digests keyed, $((n + 1)) bad inputs refused"
}

case "${1:-}" in
    --self-test) self_test ;;
    --from-json)
        [ $# -eq 3 ] || fail "usage: --from-json <file> <flavour>"
        report "$3" "$(cat "$2")"
        ;;
    --digests) report_digests ;;
    "") fail "usage: resolve-base.sh <flavour> | --digests | --from-json <file> <flavour> | --self-test" ;;
    *) report "$1" "$(inspect_remote "$1")" ;;
esac
