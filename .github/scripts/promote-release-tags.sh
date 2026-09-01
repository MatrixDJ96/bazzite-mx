#!/usr/bin/env bash
# Promote one stream's signed staging digests onto their release tags.
#
# Usage:
#   promote-release-tags.sh <stream_name>
#
# Reads the promote-*-<stream_name> manifests downloaded under promote/ and
# digest-copies each flavour's signed staging manifest onto its tag list.
# Env: GH_TOKEN (gh auth), GITHUB_REPOSITORY, IMAGE_REGISTRY, MATRIX_INCLUDE
# (the JSON build matrix — the expected flavour count is DERIVED from it,
# never a literal, so a flavour change moves the gate with it).
#
# Per-stream gate: a manifest shortfall aborts BEFORE any tag moves. A
# flavour whose sibling never built must not ship, while the OTHER stream's
# promotion, running in its own job, stays untouched — the failure is loud,
# never a silent skip.
set -euo pipefail

STREAM="${1:?stream_name required}"
MATRIX_INCLUDE="${MATRIX_INCLUDE:?MATRIX_INCLUDE (JSON build matrix) required}"

EXPECTED=$(jq --arg s "$STREAM" '[.[] | select(.stream_name == $s)] | length' <<< "$MATRIX_INCLUDE")
if ! [ "$EXPECTED" -gt 0 ] 2>/dev/null; then
  echo "::error::no ${STREAM} entries in the build matrix — this stream should never have reached promotion"
  exit 1
fi

shopt -s nullglob
manifests=(promote/promote-*-"${STREAM}"/promote.env)
echo "Promotion manifests for ${STREAM}: ${#manifests[@]} of ${EXPECTED} expected"
if [ "${#manifests[@]}" -gt 0 ]; then
  printf ' - %s\n' "${manifests[@]}"
fi
if [ "${#manifests[@]}" -ne "$EXPECTED" ]; then
  echo "::error::incomplete ${STREAM} matrix: ${#manifests[@]} of ${EXPECTED} flavours produced a promotion manifest — nothing promoted for the ${STREAM} stream"
  exit 1
fi

# Transient GHCR flakiness: same 3 × 15 s envelope the nick-fields/retry
# wrapper gave the whole loop, applied per copy (copies are idempotent).
retry() {
  local n
  for n in 1 2 3; do
    "$@" && return 0
    [ "$n" -eq 3 ] && return 1
    sleep 15
  done
}

REGISTRY="${IMAGE_REGISTRY,,}"
# A tag already claimed by a GitHub Release stays pinned to its digest:
# re-pushing it on a later rebuild would silently repoint yesterday's signed
# release. Defensive — since the upstream stream-version alias was dropped
# from the tag list (repo-audit 2026-09-01) no generated tag should collide
# with a past release tag, but the guard is what makes that a certainty.
# gh exits 0 with empty output when the repo has no releases yet.
RELEASED=$(gh release list --repo "$GITHUB_REPOSITORY" --limit 200 --json tagName -q '.[].tagName')
for manifest in "${manifests[@]}"; do
  # shellcheck disable=SC1090 # written by this run's own build jobs
  source "$manifest"
  OUTPUT_IMAGE="${REGISTRY}/${IMAGE_NAME}"
  # sort -u: TAGS is de-duplicated defensively — the metadata step owns the
  # list and a future addition may alias an existing entry.
  # shellcheck disable=SC2086 # TAGS is a space-separated list by contract
  for tag in $(printf '%s\n' $TAGS | sort -u); do
    if [ "$tag" != "$RELEASE_TAG" ] && printf '%s\n' "$RELEASED" | grep -qxF "$tag"; then
      echo "::warning::skip ${IMAGE_NAME}:${tag}: tag of an existing release, kept pinned to its digest"
      continue
    fi
    retry skopeo copy --preserve-digests \
      "docker://${OUTPUT_IMAGE}@${DIGEST}" \
      "docker://${OUTPUT_IMAGE}:${tag}"
  done
done
