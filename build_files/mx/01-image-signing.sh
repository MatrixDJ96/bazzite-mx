#!/usr/bin/bash
# MX block 01: make the image trust its own signatures. Ships the repo's
# cosign public key and a sigstoreSigned policy scope for ghcr.io/matrixdj96,
# so a host on the `ostree-image-signed` transport (the image-ref that
# 00-image-info.sh stamps into image-info.json, and what `ujust rebase-helper`
# offers) verifies every pulled update against OUR key instead of falling
# through to the base policy's docker "" = insecureAcceptAnything catch-all.
#
# Pattern lifted from the ublue-os-signing 0.5 package the base installs
# (/etc/pki/containers/ublue-os.pub + registries.d/ublue-os.yaml + the
# ghcr.io/ublue-os scope in policy.json) and aurora's
# .github/setup-runner-keys.sh (jq edit written to a sibling file and mv'd
# over: a fresh inode, so the torn-writeback rule of gotcha #34 is met).
# Divergence #25 documents the design and the host-side switch.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

CTX="${CTX:-/ctx}"
KEY_SRC="$CTX/cosign.pub"
KEY_DST=/etc/pki/containers/matrixdj96.pub
POLICY=/etc/containers/policy.json
SCOPE=ghcr.io/matrixdj96

# The key: a PEM public key, copied onto a fresh inode by install(1).
grep -q '^-----BEGIN PUBLIC KEY-----$' "$KEY_SRC"
install -D -m 0644 "$KEY_SRC" "$KEY_DST"

# The policy scope. The base policy must keep `default: reject`: ostree-ext
# refuses the signed transport outright when the default is
# insecureAcceptAnything, so a base that flipped it would break every
# verified rebase. Fail here, not on the user's host.
jq -e '.default[0].type == "reject"' "$POLICY"
jq --arg scope "$SCOPE" --arg key "$KEY_DST" \
    '.transports.docker[$scope] = [{
        "type": "sigstoreSigned",
        "keyPath": $key,
        "signedIdentity": { "type": "matchRepository" }
    }]' "$POLICY" > "$POLICY.tmp"
mv -f "$POLICY.tmp" "$POLICY"
chmod 0644 "$POLICY"

# Prove the merge kept the base scopes and added ours.
jq -e --arg scope "$SCOPE" --arg key "$KEY_DST" '
    (.transports.docker[$scope] | length) == 1
    and .transports.docker[$scope][0].type == "sigstoreSigned"
    and .transports.docker[$scope][0].keyPath == $key
    and .transports.docker[$scope][0].signedIdentity.type == "matchRepository"
    and (.transports.docker["ghcr.io/ublue-os"] | length) >= 1
    and .transports.docker[""][0].type == "insecureAcceptAnything"
' "$POLICY"

# registries.d/matrixdj96.yaml (use-sigstore-attachments) is shipped by
# system_files; assert it landed so the policy never points at a scope the
# signature fetcher ignores.
grep -qxF '  ghcr.io/matrixdj96:' /etc/containers/registries.d/matrixdj96.yaml
grep -qxF '    use-sigstore-attachments: true' /etc/containers/registries.d/matrixdj96.yaml

echo "::endgroup::"
