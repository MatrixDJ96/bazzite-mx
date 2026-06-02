#!/usr/bin/env bash
# PostToolUse(Edit|Write): enforce critical convention #1 — every third-party
# .repo under system_files/etc/yum.repos.d/ must ship enabled=0 (runtime-enabled
# per-install via a ujust recipe). Warns the agent if an edited .repo is left
# enabled=1. No-op for any other path.
set -u

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$file" ] || exit 0
case "$file" in
  */system_files/etc/yum.repos.d/*.repo) ;;
  *) exit 0 ;;
esac
[ -f "$file" ] || exit 0

if grep -Eq '^enabled=1' "$file"; then
  echo "Critical convention #1 violated: $file contains 'enabled=1'." >&2
  echo "Third-party .repo files must ship 'enabled=0' (dnf5 setopt is a silent no-op on these — use sed). Set enabled=0, then register the basename in OTHER_REPOS in build_files/shared/validate-repos.sh and enable it per-install via the ujust recipe." >&2
  exit 2
fi
exit 0
