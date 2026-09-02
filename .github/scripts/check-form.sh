#!/usr/bin/env bash
# The form rules of docs/conventions.md § Bash → Form as a check: the line
# width and the control-flow shapes the rules ban. The edit hook runs it on
# every shell file an edit touches; the lint job runs its self-test, then the
# check over the whole shell catalogue.
#
# Usage: check-form.sh <file>...
#        check-form.sh --self-test
# Output: one `<file>:<line>: <rule>` line per finding on stdout, then a
# `form ok: N file(s)` or `form: N finding(s) in M file(s)` line.
# Exit status: 0 clean, 1 findings or a file that cannot be read.
set -euo pipefail

MAX_COLUMNS=100
LITERAL_MARKER='# form: literal$'

# --- the rules ----------------------------------------------------------------
#
# Each rule is a name and an extended regex over one code line. Comment lines
# are skipped for the shape rules and counted for the width rule. Lines that
# open or continue a condition (`if`, `elif`, `while`, `until`, a leading
# `&&` or `||`) may combine `&&` and `||`: that is a boolean, not flow. A line
# ending in `# form: literal` holds a banned shape as data (a pattern, a test
# fixture) and is skipped by the shape rules. The last rule is not a shape but
# a failure: `grep -q` exits at the first match and closes the pipe, the
# writer dies of SIGPIPE and `pipefail` turns a passing check red once in a
# few hundred runs (docs/gotchas.md § `command | grep -q` under `pipefail`).

RULE_NAMES=(
    "a trailing || used as control flow: write if ! …; then … fi"
    "|| { … } used as control flow: write if ! …; then … fi"
    "a && b || c used as control flow: write if … then … else … fi" # form: literal
    "a negated command as a guard (! cmd || …): write if cmd; then … fi"
    "a subshell as a guard (( … ) || …): let the function return a status"
    "if … then … fi on one line: one action per line"
    "a pipe into grep -q: capture the output, then grep the variable (SIGPIPE under pipefail)"
)
RULE_PATTERNS=(
    '\|\| *(return|exit|die|fail|fail_build|exit_with_error|err)( |$)'
    '\|\| *\{ *$'
    '&&.*\|\|' # form: literal
    '^[[:space:]]*! .*\|\|'
    '^[[:space:]]*\(.*\) *\|\|'
    '; *then .*; *(fi|else)( |$)'
    '(^|[^|])\|[[:space:]]*grep[[:space:]]+(-[[:alpha:]]*q|--quiet)' # form: literal
)

opens_a_condition() {
    local line=$1

    [[ $line =~ ^[[:space:]]*(if|elif|while|until|\|\||\&\&)[[:space:]] ]]
}

# --- one file -----------------------------------------------------------------

# Findings on stdout, status 1 when there is at least one.
check_file() {
    local file=$1 line_number=0 line findings=0 i

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))

        if [ "${#line}" -gt "$MAX_COLUMNS" ]; then
            echo "$file:$line_number: ${#line} columns, the limit is $MAX_COLUMNS"
            findings=$((findings + 1))
        fi

        if [[ $line =~ ^[[:space:]]*# ]] || [[ $line =~ $LITERAL_MARKER ]]; then
            continue
        fi
        for i in "${!RULE_PATTERNS[@]}"; do
            if [ "$i" -eq 2 ] && opens_a_condition "$line"; then
                continue
            fi
            if [[ $line =~ ${RULE_PATTERNS[$i]} ]]; then
                echo "$file:$line_number: ${RULE_NAMES[$i]}"
                findings=$((findings + 1))
            fi
        done
    done < "$file"

    [ "$findings" -eq 0 ]
}

check_files() {
    local file files=0 files_with_findings=0 output findings=0

    for file in "$@"; do
        if [ ! -r "$file" ]; then
            echo "check-form: cannot read $file" >&2
            return 1
        fi
        files=$((files + 1))

        if output=$(check_file "$file"); then
            continue
        fi
        printf '%s\n' "$output"
        files_with_findings=$((files_with_findings + 1))
        findings=$((findings + $(wc -l <<< "$output")))
    done

    if [ "$findings" -gt 0 ]; then
        echo "form: $findings finding(s) in $files_with_findings file(s)"
        return 1
    fi
    echo "form ok: $files file(s)"
}

# --- self-test ----------------------------------------------------------------
#
# A clean file passes, every banned shape is caught by its own rule and by no
# other, and the two boolean conditions that look like rule 3 pass.

self_test_failed() {
    echo "self-test: $*"
    exit 1
}

write_clean_file() {
    cat > "$1" << 'EOF'
#!/usr/bin/env bash
# A file in the form the rules ask for.
set -euo pipefail

if ! out=$(command_that_may_fail); then
    exit 1
fi
if [ -n "$out" ] && [ "$out" != no ] \
    || [ -z "${FORCE:-}" ]; then
    echo "$out"
fi
while [ "$a" -gt 0 ] && [ "$b" -gt 0 ] || [ "$c" -eq 1 ]; do
    a=$((a - 1))
done
EOF
}

# One line per rule, in rule order, each breaking exactly its rule.
BAD_LINES=(
    'out=$(cmd) || return 1'           # form: literal
    'cmd || {'                         # form: literal
    'test -f x && echo yes || echo no' # form: literal
    '! grep -q x file || echo "x"'     # form: literal
    '(cd dir) || echo no'              # form: literal
    'if [ -f x ]; then rm x; fi'       # form: literal
    'rpm -qa | grep -q x'              # form: literal
)

self_test() {
    local dir i bad output long_line

    dir=$(mktemp -d)
    # shellcheck disable=SC2064  # expand now: the local is gone at EXIT
    trap "rm -rf '$dir'" EXIT

    write_clean_file "$dir/clean.sh"
    if ! check_files "$dir/clean.sh" > /dev/null; then
        self_test_failed "the clean file has findings:" "$(check_files "$dir/clean.sh" || true)"
    fi

    for i in "${!BAD_LINES[@]}"; do
        bad=$dir/bad-$i.sh
        printf '#!/usr/bin/env bash\n%s\n' "${BAD_LINES[$i]}" > "$bad"
        output=$(check_files "$bad" || true)
        if ! grep -qF "$bad:2: ${RULE_NAMES[$i]}" <<< "$output"; then
            self_test_failed "rule $i missed its line: ${BAD_LINES[$i]}" "$output"
        fi
        if [ "$(grep -c "^$bad:" <<< "$output")" -ne 1 ]; then
            self_test_failed "rule $i's line hit more than one rule:" "$output"
        fi
    done

    long_line=$(printf 'echo %0101d' 0)
    printf '#!/usr/bin/env bash\n%s\n' "$long_line" > "$dir/long.sh"
    output=$(check_files "$dir/long.sh" || true)
    if ! grep -q "^$dir/long.sh:2: 106 columns" <<< "$output"; then
        self_test_failed "a 106-column line passed:" "$output"
    fi

    printf '#!/usr/bin/env bash\n# %s\n' "$long_line" > "$dir/long-comment.sh"
    if check_files "$dir/long-comment.sh" > /dev/null; then
        self_test_failed "a 108-column comment passed"
    fi

    echo "self-test ok: 1 clean file, ${#BAD_LINES[@]} banned shapes each caught once," \
        "2 long lines caught"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    "")
        echo "usage: check-form.sh <file>... | --self-test" >&2
        exit 1
        ;;
    *)
        check_files "$@"
        ;;
esac
