#!/usr/bin/env bash
# Single owner of the flavour set: one line per image, "<image_name> <base_image>".
#
# Usage:
#   list-flavours.sh            # bazzite-mx bazzite / bazzite-mx-nvidia bazzite-nvidia / …
#   list-flavours.sh --names    # image names only, one per line
#
# Every workflow and script that enumerates the images reads this list (the
# build matrix plan, the upstream watcher, the release job, the GHCR cleanup,
# the release-tag resolver, the changelog), so adding or renaming a flavour is
# one edit here. Order matters: it is the order the release notes list them in.
set -euo pipefail

FLAVOURS=(
  "bazzite-mx bazzite"
  "bazzite-mx-nvidia bazzite-nvidia"
  "bazzite-mx-nvidia-open bazzite-nvidia-open"
)

case "${1:-}" in
  "")       printf '%s\n' "${FLAVOURS[@]}" ;;
  --names)  printf '%s\n' "${FLAVOURS[@]}" | cut -d' ' -f1 ;;
  *) echo "usage: $0 [--names]" >&2; exit 2 ;;
esac
