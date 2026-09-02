#!/usr/bin/env bash
# Smoke test of 01-system-files.sh: every file under system_files/ is in the
# image, byte for byte, mode included.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree),
# with the repo at ../.. so system_files/ is readable.
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

SOURCE_TREE=$(dirname "$(realpath "$0")")/../../system_files

# One FAIL line per file that is missing, differs or carries another mode;
# one OK line when every file matched.
check_system_files() {
    local file target count=0 failed=0

    while IFS= read -r -d '' file; do
        target=${file#"$SOURCE_TREE"}
        count=$((count + 1))

        if [ ! -f "$target" ]; then
            echo "FAIL: $target missing from the image"
            failed=1
        elif ! cmp -s "$file" "$target"; then
            echo "FAIL: $target differs from system_files"
            failed=1
        elif [ "$(stat -c %a "$file")" != "$(stat -c %a "$target")" ]; then
            echo "FAIL: $target mode $(stat -c %a "$target"), expected $(stat -c %a "$file")"
            failed=1
        fi
    done < <(find "$SOURCE_TREE" -type f -print0)

    if [ "$failed" -eq 0 ]; then
        echo "OK: $count system files present and identical"
    fi

    if [ "$count" -eq 0 ]; then
        echo "FAIL: system_files is empty"
    fi
}

check_system_files
