#!/usr/bin/env bash
# Resolve the upstream Bazzite tag a build tracks and print it on stdout.
#
# Usage:
#   resolve-upstream-tag.sh <stream_name> [upstream_tag]
#
# stream_name: stable | testing. upstream_tag empty = the latest release of
# that stream on ublue-os/bazzite. Env: GH_TOKEN (gh auth).
#
# Single owner of two rules every caller used to carry its own copy of
# (gotcha #22 bit one of them):
#   1. "latest for the stream": stable = the repo's latest release; testing =
#      the newest release whose tag starts with testing-, by publishedAt.
#   2. A three-group tag ([testing-]MAJOR.DATE.N) is either a genuine upstream
#      same-day rebuild (kept, we build on it) or a stray downstream .N fed
#      through a dispatch (404s as an upstream release): 404-gate it and
#      strip the .N when upstream does not know it.
set -euo pipefail

STREAM="${1:?stream_name required (stable|testing)}"
UP="${2:-}"

case "$STREAM" in
  stable|testing) ;;
  *) echo "::error::unknown stream '${STREAM}' (expected stable|testing)" >&2; exit 1 ;;
esac

if [ -z "$UP" ]; then
  if [ "$STREAM" = "stable" ]; then
    UP=$(gh release view --repo ublue-os/bazzite --json tagName -q .tagName)
  else
    UP=$(gh release list --repo ublue-os/bazzite --json tagName,publishedAt --limit 50 \
      | jq -r '[.[] | select(.tagName|startswith("testing-"))] | sort_by(.publishedAt) | last | .tagName')
  fi
fi
[ -n "$UP" ] && [ "$UP" != "null" ] || {
  echo "::error::could not resolve the latest ${STREAM} tag on ublue-os/bazzite" >&2
  exit 1
}

if [[ "$UP" =~ ^(testing-)?[0-9]+\.[0-9]+\.[0-9]+$ ]] \
   && ! gh release view --repo ublue-os/bazzite "$UP" >/dev/null 2>&1; then
  echo "::warning::upstream tag ${UP} not found on ublue-os/bazzite; using ${UP%.*}" >&2
  UP="${UP%.*}"
fi

echo "$UP"
