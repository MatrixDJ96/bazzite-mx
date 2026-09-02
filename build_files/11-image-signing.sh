#!/usr/bin/env bash
# Trust for our own updates: a host verifies every pull of ghcr.io/matrixdj96
# against the repo's cosign key. matchRepository keeps the tag out of it,
# because a host follows :stable while the signature is on the digest.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

KEY_SRC=$CTX/cosign.pub
KEY=/etc/pki/containers/matrixdj96.pub
POLICY=/etc/containers/policy.json
SCOPE=ghcr.io/matrixdj96

[ -s "$KEY_SRC" ] || die "$KEY_SRC missing from the build context"
grep -q 'BEGIN PUBLIC KEY' "$KEY_SRC" || die "$KEY_SRC is not a PEM public key"
install -Dm0644 "$KEY_SRC" "$KEY"

[ -f "$POLICY" ] || die "$POLICY missing from the base"
jq --arg scope "$SCOPE" --arg key "$KEY" \
    '.transports.docker[$scope] = [{
        type: "sigstoreSigned",
        keyPath: $key,
        signedIdentity: { type: "matchRepository" }
    }]' "$POLICY" > "$POLICY.new"
jq -e --arg scope "$SCOPE" '.transports.docker[$scope][0].keyPath' "$POLICY.new" > /dev/null \
    || die "policy.json: scope $SCOPE not written"
mv -f "$POLICY.new" "$POLICY"

log "image-signing: $SCOPE verified with $KEY"
