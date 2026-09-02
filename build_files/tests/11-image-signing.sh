#!/usr/bin/env bash
# Smoke test of 11-image-signing.sh: our key, its policy scope, the sigstore
# attachment stanza, and the base's own trust untouched.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree),
# with the repo at ../.. so cosign.pub is readable.
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

CTX=$(dirname "$(realpath "$0")")/../..
KEY=/etc/pki/containers/matrixdj96.pub
POLICY=/etc/containers/policy.json
REGISTRIES_STANZA=/etc/containers/registries.d/matrixdj96.yaml
SCOPE=ghcr.io/matrixdj96

check_key() {
    if [ -f "$KEY" ] && cmp -s "$KEY" "$CTX/cosign.pub"; then
        echo "OK: $KEY is the repo's cosign.pub ($(sha256sum "$KEY" | cut -c1-12))"
    else
        echo "FAIL: $KEY missing or not the repo's cosign.pub"
    fi
}

check_policy_scope() {
    local scope_entry
    local wanted='.transports.docker[$scope]
        | length == 1
          and .[0].type == "sigstoreSigned"
          and .[0].keyPath == $key
          and .[0].signedIdentity.type == "matchRepository"'

    if jq -e --arg scope "$SCOPE" --arg key "$KEY" "$wanted" "$POLICY" > /dev/null; then
        echo "OK: policy.json scope $SCOPE is sigstoreSigned with matchRepository"
    else
        scope_entry=$(jq -c --arg scope "$SCOPE" '.transports.docker[$scope]' "$POLICY")
        echo "FAIL: policy.json scope: $scope_entry"
    fi
}

check_base_policy_kept() {
    local base_entries
    local wanted='.default[0].type == "reject"
        and (.transports.docker["ghcr.io/ublue-os"][0].type == "sigstoreSigned")'

    if jq -e "$wanted" "$POLICY" > /dev/null; then
        echo "OK: base policy kept (default reject, ublue-os scope signed)"
    else
        base_entries=$(jq -c '{default, ublue: .transports.docker["ghcr.io/ublue-os"]}' "$POLICY")
        echo "FAIL: base policy changed: $base_entries"
    fi
}

check_registries_stanza() {
    if [ -f "$REGISTRIES_STANZA" ] \
        && grep -q "^  $SCOPE:$" "$REGISTRIES_STANZA" \
        && grep -q '^    use-sigstore-attachments: true$' "$REGISTRIES_STANZA"; then
        echo "OK: registries.d stanza for $SCOPE with sigstore attachments"
    else
        echo "FAIL: $REGISTRIES_STANZA missing or without the sigstore stanza"
    fi
}

check_key
check_policy_scope
check_base_policy_kept
check_registries_stanza
