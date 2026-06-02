#!/usr/bin/env bash
# Emit the Markdown body for a bazzite-mx GitHub Release on stdout:
# intro + Upstream section (Bazzite compare diff) + image digest table
# for the 3 variants + commits table + How-to-rebase + cosign verify hint.
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

UPSTREAM_REPO="ublue-os/bazzite"
COSIGN_PUB_URL="https://raw.githubusercontent.com/${REPO}/main/cosign.pub"

# Map a downstream release tag to the upstream Bazzite tag it was built off.
# An upstream tag is `[testing-]MAJOR.DATE` (two numeric groups); a downstream
# rebuild appends a third numeric group `.N`. Strip that `.N` when present, so a
# stray downstream tag fed in as the upstream tag can never produce a 404 link.
upstream_of() {
  local tag="$1"
  if [[ "${tag}" =~ ^(testing-)?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${tag%.*}"
  else
    echo "${tag}"
  fi
}

# Sanitise the upstream tag and derive the previous upstream tag.
UPSTREAM_TAG="$(upstream_of "${UPSTREAM_TAG}")"
UPSTREAM_URL="https://github.com/${UPSTREAM_REPO}/releases/tag/${UPSTREAM_TAG}"

PREV_UPSTREAM=""
if [[ -n "${PREV_TAG}" ]]; then
  PREV_UPSTREAM="$(upstream_of "${PREV_TAG}")"
fi

# A downstream rebuild has RELEASE_TAG = <UPSTREAM_TAG>.<N>, i.e. the release tag
# carries a third numeric group the sanitised upstream tag does not.
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

Previous release: [\`${PREV_TAG}\`](${PREV_URL}).
EOF
fi

# --- Upstream section ------------------------------------------------------
# The real delta between two bazzite-mx releases is almost always the upstream
# Bazzite bump. Show the compare diff when the upstream tag moved; otherwise say
# plainly that this is a same-upstream rebuild with no upstream changes.
cat <<EOF

### Upstream
EOF
if [[ -n "${PREV_UPSTREAM}" && "${PREV_UPSTREAM}" != "${UPSTREAM_TAG}" ]]; then
  COMPARE_URL="https://github.com/${UPSTREAM_REPO}/compare/${PREV_UPSTREAM}...${UPSTREAM_TAG}"
  echo ""
  echo "Bazzite \`${PREV_UPSTREAM}\` → \`${UPSTREAM_TAG}\` — [compare upstream changes ↗](${COMPARE_URL})."
elif [[ "${IS_REBUILD}" == "yes" ]]; then
  echo ""
  echo "Downstream rebuild on the same upstream tag \`${UPSTREAM_TAG}\` — no upstream changes."
else
  echo ""
  echo "Tracks Bazzite \`${UPSTREAM_TAG}\`."
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

# --- Commits table (downstream repo changes, when there are any) ------------
if [[ -n "${PREV_TAG}" ]]; then
  COMMITS="$(git log "${PREV_TAG}..HEAD" \
    --pretty=format:"| **[\`%h\`](https://github.com/${REPO}/commit/%H)** | %s | %an |" \
    2>/dev/null || true)"
  cat <<EOF

### Commits (bazzite-mx)
EOF
  if [[ -n "${COMMITS}" ]]; then
    cat <<EOF

| Hash | Subject | Author |
| --- | --- | --- |
${COMMITS}
EOF
  else
    echo ""
    echo "_No downstream changes — this release only refreshes against upstream._"
  fi
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
