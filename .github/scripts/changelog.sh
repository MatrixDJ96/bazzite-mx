#!/usr/bin/env bash
# Emit the Markdown body for a bazzite-mx GitHub Release on stdout.
#
# Body layout follows ublue-os/bazzite's generate_release.yml output (intro +
# tables + How-to-rebase), simplified for the no-SBOM flavour: we keep our
# value-adds (digest table for the 3 image variants + cosign verify hint)
# and skip the upstream "Major packages / All Images / KDE Images" diffs
# that would require syft+ORAS.
#
# Usage:
#   changelog.sh <upstream_tag> <release_tag> <prev_tag> \
#                <digest_main> <digest_nvidia> <digest_nvidia_open> \
#                [stream_name]
#
# stream_name (default "stable") drives the bootc switch tag in "How to rebase"
# (:stable vs :testing) so users land on the right mutable channel.
#
# Env vars (auto-populated by GitHub Actions, override for local testing):
#   GITHUB_REPOSITORY_OWNER  e.g. MatrixDJ96
#   GITHUB_REPOSITORY        e.g. MatrixDJ96/bazzite-mx
set -euo pipefail

UPSTREAM_TAG="${1:?upstream_tag required}"
RELEASE_TAG="${2:?release_tag required}"
PREV_TAG="${3:-}"
DIGEST_MAIN="${4:?digest for bazzite-mx required}"
DIGEST_NVIDIA="${5:?digest for bazzite-mx-nvidia required}"
DIGEST_NVIDIA_OPEN="${6:?digest for bazzite-mx-nvidia-open required}"
STREAM_NAME="${7:-stable}"

OWNER="${GITHUB_REPOSITORY_OWNER:-MatrixDJ96}"
OWNER_LC="${OWNER,,}"
REPO="${GITHUB_REPOSITORY:-${OWNER}/bazzite-mx}"

UPSTREAM_URL="https://github.com/ublue-os/bazzite/releases/tag/${UPSTREAM_TAG}"
COSIGN_PUB_URL="https://raw.githubusercontent.com/${REPO}/main/cosign.pub"

# A downstream rebuild has RELEASE_TAG = <UPSTREAM_TAG>.<N> (or
# <stream>-<UPSTREAM_TAG>.<N> for testing), i.e. RELEASE_TAG != UPSTREAM_TAG.
IS_REBUILD="no"
if [[ "${RELEASE_TAG}" != "${UPSTREAM_TAG}" ]]; then
  IS_REBUILD="yes"
fi

# --- Intro paragraph -------------------------------------------------------
if [[ -z "${PREV_TAG}" ]]; then
  COUNT="$(git rev-list --count HEAD 2>/dev/null || echo "?")"
  cat <<EOF
This is an automatically generated changelog for \`bazzite-mx\` release \`${RELEASE_TAG}\`, built off [\`ublue-os/bazzite@${UPSTREAM_TAG}\`](${UPSTREAM_URL}).

This is the initial release. ${COUNT} commits in the repository at the time of build.
EOF
else
  PREV_URL="https://github.com/${REPO}/releases/tag/${PREV_TAG}"
  cat <<EOF
This is an automatically generated changelog for \`bazzite-mx\` release \`${RELEASE_TAG}\`, built off [\`ublue-os/bazzite@${UPSTREAM_TAG}\`](${UPSTREAM_URL}).

From previous version [\`${PREV_TAG}\`](${PREV_URL}) there have been the following changes.
EOF
fi

if [[ "${IS_REBUILD}" == "yes" ]]; then
  echo ""
  echo "This release is a **downstream rebuild** on the same upstream tag — no upstream changes."
fi

# --- Images table (our value-add) ------------------------------------------
cat <<EOF

### Images

| Variant | Pull reference (immutable digest) |
| --- | --- |
| \`bazzite-mx\` | \`ghcr.io/${OWNER_LC}/bazzite-mx@${DIGEST_MAIN}\` |
| \`bazzite-mx-nvidia\` | \`ghcr.io/${OWNER_LC}/bazzite-mx-nvidia@${DIGEST_NVIDIA}\` |
| \`bazzite-mx-nvidia-open\` | \`ghcr.io/${OWNER_LC}/bazzite-mx-nvidia-open@${DIGEST_NVIDIA_OPEN}\` |
EOF

# --- Commits table (only when we have a previous release) ------------------
if [[ -n "${PREV_TAG}" ]]; then
  cat <<EOF

### Commits

| Hash | Subject | Author |
| --- | --- | --- |
EOF
  if ! git log "${PREV_TAG}..HEAD" \
        --pretty=format:"| **[\`%h\`](https://github.com/${REPO}/commit/%H)** | %s | %an |" \
        2>/dev/null; then
    echo "| _no commits since previous release — refresh against upstream only_ | | |"
  fi
  echo
fi

# --- How to rebase ---------------------------------------------------------
cat <<EOF

### How to rebase

For current users, run:

\`\`\`bash
# For the latest ${STREAM_NAME} (mobile tag, follows future releases automatically):
sudo bootc switch ghcr.io/${OWNER_LC}/bazzite-mx:${STREAM_NAME}

# For this specific release (immutable, pinned):
sudo bootc switch ghcr.io/${OWNER_LC}/bazzite-mx:${RELEASE_TAG}
\`\`\`

### Verify

Each image is signed at build time. Before rebasing in security-sensitive contexts:

\`\`\`bash
cosign verify --key ${COSIGN_PUB_URL} <ref>
\`\`\`
EOF
