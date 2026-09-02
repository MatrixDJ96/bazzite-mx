#!/usr/bin/env bash
# Every file under system_files/ is in the image, byte for byte, mode included.
set -euo pipefail

SRC=$(dirname "$(realpath "$0")")/../../system_files
n=0
bad=0
while IFS= read -r -d '' f; do
    rel=${f#"$SRC"}
    n=$((n + 1))
    if [ ! -f "$rel" ]; then
        echo "FAIL: $rel missing from the image"
        bad=1
    elif ! cmp -s "$f" "$rel"; then
        echo "FAIL: $rel differs from system_files"
        bad=1
    elif [ "$(stat -c %a "$f")" != "$(stat -c %a "$rel")" ]; then
        echo "FAIL: $rel mode $(stat -c %a "$rel"), expected $(stat -c %a "$f")"
        bad=1
    fi
done < <(find "$SRC" -type f -print0)
[ "$bad" = 0 ] && echo "OK: $n system files present and identical"
[ "$n" -gt 0 ] || echo "FAIL: system_files is empty"
