#!/usr/bin/env bash
# PostToolUse(Edit|Write): lint an edited shell script with shellcheck and feed
# warning+error findings back to the agent. No-op when jq/shellcheck are absent
# (shellcheck lives in a host-local path on some machines), when the edited file
# is not a *.sh, when it no longer exists, or when it is clean.
set -u

command -v jq >/dev/null 2>&1 || exit 0
command -v shellcheck >/dev/null 2>&1 || exit 0

input=$(cat)
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$file" ] || exit 0
case "$file" in
  *.sh) ;;
  *) exit 0 ;;
esac
[ -f "$file" ] || exit 0

# Restrict to warning+error severity to avoid style/info noise.
out=$(shellcheck --severity=warning --format=gcc "$file" 2>/dev/null) || true
if [ -n "$out" ]; then
  echo "shellcheck (warning+) reported issues in $file:" >&2
  echo "$out" >&2
  exit 2
fi
exit 0
