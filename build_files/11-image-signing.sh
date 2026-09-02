#!/usr/bin/env bash
# Trust for our own updates: a host verifies every pull of ghcr.io/matrixdj96
# against the repo's cosign key. matchRepository keeps the tag out of it,
# because a host follows :stable while the signature is on the digest.
#
# Usage: run by build.sh; no arguments. Reads cosign.pub at the repo root.
# Writes: /etc/pki/containers/matrixdj96.pub and the scope in
#   /etc/containers/policy.json.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

KEY_SOURCE=$CTX/cosign.pub
KEY=/etc/pki/containers/matrixdj96.pub
POLICY=/etc/containers/policy.json
SCOPE=ghcr.io/matrixdj96

# --- the steps ----------------------------------------------------------------

install_key() {
    if [ ! -s "$KEY_SOURCE" ]; then
        fail_build "$KEY_SOURCE missing from the build context"
    fi

    if ! grep -q 'BEGIN PUBLIC KEY' "$KEY_SOURCE"; then
        fail_build "$KEY_SOURCE is not a PEM public key"
    fi

    install -Dm0644 "$KEY_SOURCE" "$KEY"
}

# The scope is read back from the new file before the rename, so a jq that
# wrote something else never reaches the image.
write_policy_scope() {
    if [ ! -f "$POLICY" ]; then
        fail_build "$POLICY missing from the base"
    fi

    jq --arg scope "$SCOPE" --arg key "$KEY" \
        '.transports.docker[$scope] = [{
            type: "sigstoreSigned",
            keyPath: $key,
            signedIdentity: { type: "matchRepository" }
        }]' "$POLICY" > "$POLICY.new"

    if ! jq -e --arg scope "$SCOPE" '.transports.docker[$scope][0].keyPath' "$POLICY.new" \
        > /dev/null; then
        fail_build "policy.json: scope $SCOPE not written"
    fi

    mv -f "$POLICY.new" "$POLICY"
}

# --- main ---------------------------------------------------------------------

install_key
write_policy_scope

log "image-signing: $SCOPE verified with $KEY"
