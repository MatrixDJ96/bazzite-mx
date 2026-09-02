#!/usr/bin/env bash
# PostToolUse(Edit|Write): lint an edited shell script the way CI does, with
# ShellCheck at warning severity and shfmt's diff, and feed the findings back
# to the agent (exit 2). Silent on anything else, including a clean script.
# Only -u, on purpose: a hook that died on a missing linter or a failing
# podman would block the edit it is meant to comment on. Every command that
# may fail is guarded, and the only non-zero exit is the deliberate 2.
set -u

command -v jq > /dev/null 2>&1 || exit 0

input=$(cat)
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2> /dev/null)
[ -n "$file" ] || exit 0
[ -f "$file" ] || exit 0
# A shell script is a .sh file or one with the repo's shebang: the libexec
# helpers carry no extension.
case "$file" in
    *.sh) ;;
    *) [ "$(head -n1 "$file")" = '#!/usr/bin/env bash' ] || exit 0 ;;
esac

SHFMT_FLAGS=(--indent 4 --case-indent --binary-next-line --space-redirects)
CI_SHFMT_MINOR=3.7

findings=""
if command -v shellcheck > /dev/null 2>&1; then
    out=$(shellcheck -x -P SCRIPTDIR --severity=warning --format=gcc "$file" 2> /dev/null) || true
    [ -n "$out" ] && findings+="shellcheck (warning+):"$'\n'"$out"$'\n'
fi

# Fedora's shfmt prints an empty --version, so the rpm's version is read
# instead and the host binary is actually used where it is the right one.
shfmt_version() {
    local v
    v=$(shfmt --version 2> /dev/null)
    [ -n "$v" ] || v=$(rpm -q --qf '%{VERSION}' shfmt 2> /dev/null)
    printf '%s' "${v#v}"
}

# CI runs Fedora's shfmt: the host binary is used only when it is the same
# minor, otherwise the same container CI uses.
fmt=""
if command -v shfmt > /dev/null 2>&1 && [[ "$(shfmt_version)" == "${CI_SHFMT_MINOR}".* ]]; then
    fmt=$(shfmt --diff "${SHFMT_FLAGS[@]}" "$file" 2>&1) || true
elif command -v podman > /dev/null 2>&1; then
    dir=$(dirname "$file")
    fmt=$(podman run --rm --volume "$dir:/w:ro,z" quay.io/fedora/fedora:44 bash -c \
        'dnf -q install -y shfmt > /dev/null 2>&1 && shfmt --diff '"${SHFMT_FLAGS[*]}"' "/w/'"$(basename "$file")"'"' 2>&1) || true
fi
[ -n "$fmt" ] && findings+="shfmt --diff (CI flags):"$'\n'"$fmt"$'\n'

if [ -n "$findings" ]; then
    echo "lint findings in $file:" >&2
    printf '%s' "$findings" >&2
    exit 2
fi
exit 0
