#!/usr/bin/env bash
# The edit hook, PostToolUse on Edit and Write: an edited shell script is
# linted the way CI does, ShellCheck at warning severity, shfmt's diff with the
# CI flags and the form rules of check-form.sh, and the findings go back to
# the agent. Silent on anything else, a clean script included.
#
# Usage: lint-edit.sh < <hook input>
#          the hook input is the JSON Claude Code writes on stdin; the file is
#          .tool_input.file_path, a shell script when it ends in .sh or opens
#          with the repo's shebang (the libexec helpers carry no extension)
# Output: on stderr, `lint findings in <file>:` and one block per linter.
# Exit status: 2 with findings, which Claude Code shows to the agent; 0 in
#   every other case. Only -u, on purpose: a hook that died on a missing
#   linter or a failing podman would block the edit it is meant to comment
#   on, so every command that may fail is guarded and the only non-zero exit
#   is the deliberate 2.
set -u

SHFMT_FLAGS=(--indent 4 --case-indent --binary-next-line --space-redirects)
CI_SHFMT_MINOR=3.7
CI_IMAGE=quay.io/fedora/fedora:44

# --- the file -----------------------------------------------------------------

# edited_file: the file path of the hook input on stdout, nothing when the
# input has none.
edited_file() {
    local input

    input=$(cat)
    printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2> /dev/null
}

# is_shell_script <file>: status 0 for a .sh file or one opening with the
# repo's shebang.
is_shell_script() {
    local file=$1

    case "$file" in
        *.sh)
            return 0
            ;;
    esac

    [ "$(head -n1 "$file")" = '#!/usr/bin/env bash' ]
}

# --- the linters --------------------------------------------------------------

# ShellCheck's warnings and errors in gcc format: shellcheck_findings <file>,
# nothing when it is not installed or the script is clean. (The comment does
# not open with the function's name: a `# shellcheck` prefix is a directive.)
shellcheck_findings() {
    local file=$1

    if ! command -v shellcheck > /dev/null 2>&1; then
        return 0
    fi

    shellcheck -x -P SCRIPTDIR --severity=warning --format=gcc "$file" 2> /dev/null || true
}

# shfmt_version: the host shfmt's version without the v. Fedora's shfmt
# prints an empty --version, so the rpm's version is read instead.
shfmt_version() {
    local version

    version=$(shfmt --version 2> /dev/null)
    if [ -z "$version" ]; then
        version=$(rpm -q --qf '%{VERSION}' shfmt 2> /dev/null)
    fi

    printf '%s' "${version#v}"
}

# shfmt_findings <file>: shfmt's diff with the CI flags. CI runs Fedora 44's
# shfmt, so the host binary is used only when it is the same minor, otherwise
# the same container CI uses; nothing when neither route is available.
shfmt_findings() {
    local file=$1
    local dir name in_container

    if command -v shfmt > /dev/null 2>&1 \
        && [[ "$(shfmt_version)" == "${CI_SHFMT_MINOR}".* ]]; then
        shfmt --diff "${SHFMT_FLAGS[@]}" "$file" 2>&1 || true
        return 0
    fi

    if command -v podman > /dev/null 2>&1; then
        dir=$(dirname "$file")
        name=$(basename "$file")
        in_container="dnf -q install -y shfmt > /dev/null 2>&1"
        in_container+=" && shfmt --diff ${SHFMT_FLAGS[*]} '/w/$name'"
        podman run --rm --volume "$dir:/w:ro,z" "$CI_IMAGE" bash -c "$in_container" 2>&1 || true
    fi
}

# form_findings <file>: the findings of check-form.sh, the owner of the form
# rules of docs/conventions.md § Bash → Form; nothing when the file passes
# (its `form ok` line stays out of the findings) or the check is not there.
form_findings() {
    local file=$1
    local check_form output
    check_form="$(dirname "$0")/../../.github/scripts/check-form.sh"

    if [ ! -x "$check_form" ]; then
        return 0
    fi

    if output=$("$check_form" "$file" 2>&1); then
        return 0
    fi

    printf '%s\n' "$output"
}

# --- main ---------------------------------------------------------------------

# lint <file>: every linter's findings under its own heading, on stdout.
lint() {
    local file=$1
    local shellcheck_output shfmt_output form_output

    shellcheck_output=$(shellcheck_findings "$file")
    if [ -n "$shellcheck_output" ]; then
        printf '%s\n%s\n' "shellcheck (warning+):" "$shellcheck_output"
    fi

    shfmt_output=$(shfmt_findings "$file")
    if [ -n "$shfmt_output" ]; then
        printf '%s\n%s\n' "shfmt --diff (CI flags):" "$shfmt_output"
    fi

    form_output=$(form_findings "$file")
    if [ -n "$form_output" ]; then
        printf '%s\n%s\n' "check-form.sh (docs/conventions.md § Form):" "$form_output"
    fi
}

main() {
    local file findings

    if ! command -v jq > /dev/null 2>&1; then
        exit 0
    fi

    file=$(edited_file)
    if [ -z "$file" ] || [ ! -f "$file" ]; then
        exit 0
    fi
    if ! is_shell_script "$file"; then
        exit 0
    fi

    findings=$(lint "$file")
    if [ -n "$findings" ]; then
        echo "lint findings in $file:" >&2
        printf '%s\n' "$findings" >&2
        exit 2
    fi

    exit 0
}

main
