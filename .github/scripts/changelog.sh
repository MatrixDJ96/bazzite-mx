#!/usr/bin/env bash
# Emit the Markdown body for a bazzite-mx GitHub Release on stdout:
# intro + Upstream section (Bazzite compare diff) + image digest table
# for the 3 variants + commits table + How-to-rebase + cosign verify hint.
#
# Usage:
#   IMAGE_DIGESTS=$'bazzite-mx sha256:…\nbazzite-mx-nvidia sha256:…\n…' \
#   changelog.sh <upstream_tag> <release_tag> <prev_tag> [stream_name] [prev_upstream]
#
# IMAGE_DIGESTS: one "<image_name> <digest>" line per flavour, in the order the
# tables list them (the caller derives it from list-flavours.sh, so the release
# notes follow the flavour set instead of a positional argument per image).
# stream_name (default "stable") drives the bootc switch tag in "How to rebase"
# (:stable vs :testing) so users land on the right mutable channel.
# prev_upstream is the upstream tag the previous release was built off
# (recovered by the caller from that release's title); empty when unknown.
#
# Env vars (auto-populated by GitHub Actions, override for local testing):
#   GITHUB_REPOSITORY_OWNER  e.g. MatrixDJ96
#   GITHUB_REPOSITORY        e.g. MatrixDJ96/bazzite-mx
set -euo pipefail

UPSTREAM_TAG="${1:?upstream_tag required}"
RELEASE_TAG="${2:?release_tag required}"
PREV_TAG="${3:-}"
STREAM_NAME="${4:-stable}"
PREV_UPSTREAM="${5:-}"

# Fail closed on the digest hand-off: an empty or malformed line would print a
# release whose pull references point at nothing.
: "${IMAGE_DIGESTS:?IMAGE_DIGESTS (one '<image> <digest>' line per flavour) required}"
IMAGES=(); DIGESTS=()
while read -r img digest; do
  [ -n "$img" ] || continue
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "changelog.sh: bad digest for ${img}: '${digest}'" >&2
    exit 1
  }
  IMAGES+=("$img"); DIGESTS+=("$digest")
done <<< "$IMAGE_DIGESTS"
[ "${#IMAGES[@]}" -gt 0 ] || { echo "changelog.sh: IMAGE_DIGESTS carries no image" >&2; exit 1; }

OWNER="${GITHUB_REPOSITORY_OWNER:-MatrixDJ96}"
OWNER_LC="${OWNER,,}"
REPO="${GITHUB_REPOSITORY:-${OWNER}/bazzite-mx}"

UPSTREAM_REPO="ublue-os/bazzite"
COSIGN_PUB_URL="https://raw.githubusercontent.com/${REPO}/main/cosign.pub"

# The upstream tag arrives authoritative from the caller (the resolve jobs
# 404-gate it against real ublue-os/bazzite releases), so it is used verbatim —
# including upstream's own same-day rebuild suffix (e.g. testing-44.20260705.1).
UPSTREAM_URL="https://github.com/${UPSTREAM_REPO}/releases/tag/${UPSTREAM_TAG}"

# Downstream release tags live on their own calendar: [testing-]MAJOR.<build
# date>, plus a third numeric group .N for same-day rebuilds. That .N is always
# ours, so a rebuild is recognisable from the release tag alone.
IS_REBUILD="no"
if [[ "${RELEASE_TAG}" =~ ^(testing-)?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
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
elif [[ -n "${PREV_UPSTREAM}" && "${IS_REBUILD}" == "yes" ]]; then
  echo ""
  echo "Downstream rebuild on the same upstream tag \`${UPSTREAM_TAG}\` — no upstream changes."
elif [[ -n "${PREV_UPSTREAM}" ]]; then
  echo ""
  echo "Tracks Bazzite \`${UPSTREAM_TAG}\` — unchanged since the previous release."
else
  echo ""
  echo "Tracks Bazzite \`${UPSTREAM_TAG}\`."
fi

# --- Images table (our value-add) ------------------------------------------
cat <<EOF

### Images

| Variant | Pull reference (immutable digest) |
| --- | --- |
EOF
for i in "${!IMAGES[@]}"; do
  echo "| \`${IMAGES[$i]}\` | \`ghcr.io/${OWNER_LC}/${IMAGES[$i]}@${DIGESTS[$i]}\` |"
done

# --- Versions table ----------------------------------------------------------
# Kernel per flavour from the ostree.linux label of the digest-pinned images
# (skopeo only, no pull — the release runner has no disk for one; a kernel row
# is the one value that legitimately differs per flavour, e.g. bazzite-nvidia
# on the ogc-lts kernel). Core package versions come from PKG_VERSIONS_FILE,
# collected in the build job where the image is already local; when absent
# (standalone dispatch with no build in the run) the table keeps the kernel
# rows alone. Lookup failures degrade to "unknown" rather than failing the
# release: the images are already pushed and signed at this point — but they
# degrade LOUDLY: skopeo's stderr stays on the job log and a missing label
# reads as a failure too, so an "unknown" row is always traceable.
kernel_of() {
  local kernel
  if ! kernel=$(skopeo inspect --retry-times 3 --no-tags \
      --format '{{index .Labels "ostree.linux"}}' \
      "docker://ghcr.io/${OWNER_LC}/$1@$2") || [[ -z "${kernel}" ]]; then
    echo "WARNING: kernel_of: no ostree.linux label readable for $1@$2 — row degrades to 'unknown'" >&2
    kernel="unknown"
  fi
  echo "${kernel}"
}
cat <<EOF

### Versions

| Component | Version |
| --- | --- |
EOF
for i in "${!IMAGES[@]}"; do
  echo "| **Kernel** (\`${IMAGES[$i]}\`) | \`$(kernel_of "${IMAGES[$i]}" "${DIGESTS[$i]}")\` |"
done
PKG_VERSIONS_FILE="${PKG_VERSIONS_FILE:-}"
if [[ -n "${PKG_VERSIONS_FILE}" && -s "${PKG_VERSIONS_FILE}" ]]; then
  declare -A PRETTY=(
    [plasma-desktop]="KDE Plasma" [mesa-filesystem]="Mesa" [podman]="Podman"
    [docker-ce]="Docker" [distrobox]="Distrobox" [bootc]="Bootc"
    [flatpak]="Flatpak" [ostree]="OSTree" [rpm-ostree]="RPM-OSTree"
  )
  while read -r name ver; do
    [[ -z "${name}" ]] && continue
    echo "| **${PRETTY[$name]:-$name}** | ${ver} |"
  done < "${PKG_VERSIONS_FILE}"
fi

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
