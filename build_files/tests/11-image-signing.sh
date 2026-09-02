#!/usr/bin/env bash
# The signing trust: our key, its policy scope, the attachment stanza, and the
# base's own trust untouched.
set -euo pipefail

CTX=$(dirname "$(realpath "$0")")/../..
KEY=/etc/pki/containers/matrixdj96.pub
POLICY=/etc/containers/policy.json

if [ -f "$KEY" ] && cmp -s "$KEY" "$CTX/cosign.pub"; then
    echo "OK: $KEY is the repo's cosign.pub ($(sha256sum "$KEY" | cut -c1-12))"
else
    echo "FAIL: $KEY missing or not the repo's cosign.pub"
fi

if jq -e --arg key "$KEY" '.transports.docker["ghcr.io/matrixdj96"]
    | length == 1 and .[0].type == "sigstoreSigned" and .[0].keyPath == $key
      and .[0].signedIdentity.type == "matchRepository"' "$POLICY" > /dev/null; then
    echo "OK: policy.json scope ghcr.io/matrixdj96 is sigstoreSigned with matchRepository"
else
    echo "FAIL: policy.json scope: $(jq -c '.transports.docker["ghcr.io/matrixdj96"]' "$POLICY")"
fi

if jq -e '.default[0].type == "reject" and (.transports.docker["ghcr.io/ublue-os"][0].type == "sigstoreSigned")' "$POLICY" > /dev/null; then
    echo "OK: base policy kept (default reject, ublue-os scope signed)"
else
    echo "FAIL: base policy changed: $(jq -c '{default, ublue: .transports.docker["ghcr.io/ublue-os"]}' "$POLICY")"
fi

REG=/etc/containers/registries.d/matrixdj96.yaml
if [ -f "$REG" ] && grep -q '^  ghcr.io/matrixdj96:$' "$REG" && grep -q '^    use-sigstore-attachments: true$' "$REG"; then
    echo "OK: registries.d stanza for ghcr.io/matrixdj96 with sigstore attachments"
else
    echo "FAIL: $REG missing or without the sigstore stanza"
fi
