#!/usr/bin/env bash
# Checks the form rules of docs/conventions.md § Bash → Form on shell files: the
# line width, six control-flow shapes the rules ban and four failures (a pipe
# into grep -q, a || echo fallback inside $( ), a pipeline assigned bare, a $( )
# inside $(( ))).
#
# The lint job runs the self-test, then the check over the whole shell
# catalogue.
#
# Usage: check-form.sh <file>...
#          <file>  a shell file to check
#        check-form.sh --self-test
# Output: one `<file>:<line>: <rule>` line per finding on stdout, then a
#   `form ok: N file(s)` or `form: N finding(s) in M file(s)` line.
# Exit status: 0 clean, 1 findings, a bad argument or an unreadable file.
set -euo pipefail

MAX_COLUMNS=100
LITERAL_MARKER='# form: literal$'

# --- the rules ----------------------------------------------------------------
#
# Each rule is a name and an extended regex over one code line. Comment lines
# are skipped for the shape rules and counted for the width rule. Lines that
# open or continue a condition (`if`, `elif`, `while`, `until`, a leading `&&`
# or `||`) may combine `&&` and `||`: that is a boolean, not flow. A line ending
# in `# form: literal` holds a banned shape as data (a pattern, a test fixture)
# and is skipped by the shape rules. A line ending in a backslash (an odd number
# of them: `\\` is a literal backslash) is joined with the next before the shape
# rules read it, so a shape spread over a continuation is caught at its first
# line; a comment or a literal line ends the join, and a file ending inside one
# is checked as it stands. A pipeline assigned passes with `|| true` on the
# logical line or when it opens a condition (`if ! var=$(grep …); then`). A
# `$( )` spread over lines without backslashes is read line by line, so a
# pipeline assigned across them (`var=$({` … `} | sort -u)`) passes unseen, and
# so does one whose first command holds a `)` (a group in a regex).

RULE_NAMES=(
    "a trailing || used as control flow: write if ! …; then … fi"
    "|| { … } used as control flow: write if ! …; then … fi"
    "a && b || c used as control flow: write if … then … else … fi" # form: literal
    "a negated command as a guard (! cmd || …): write if cmd; then … fi"
    "a subshell as a guard (( … ) || …): let the function return a status"
    "if … then … fi on one line: one action per line"
    "a pipe into grep -q: capture the output, then grep the variable (SIGPIPE under pipefail)"
    "a || echo fallback inside \$( ): capture with || true, then print \${var:-fallback}"
    "an assignment from a pipeline or grep without || true: a failing element kills it (pipefail)"
    "a \$( ) inside \$(( )): capture it first (an empty output escapes set -e)"
)
RULE_PATTERNS=(
    '\|\| *(return|exit|die|fail|fail_build|exit_with_error|err)( |$)'
    '\|\| *\{ *$'
    '&&.*\|\|' # form: literal
    '^[[:space:]]*! .*\|\|'
    '^[[:space:]]*\(.*\) *\|\|'
    '; *then .*; *(fi|else)( |$)'
    '(^|[^|])\|[[:space:]]*grep[[:space:]]+(-[[:alpha:]]*q|--quiet)' # form: literal
    '\$\(.*\|\| *echo '                                              # form: literal
    '=\$\((grep |[^)]*[^|]\|[[:space:]]+[^|])'                       # form: literal
    '\$\(\([^)]*\$\('                                                # form: literal
)
AND_OR_INDEX=2
ASSIGNED_PIPELINE_INDEX=8
CARRIES_OR_TRUE='\|\|[[:space:]]*true'

opens_a_condition() {
    local line=$1

    [[ $line =~ ^[[:space:]]*(if|elif|while|until|\|\||\&\&)[[:space:]] ]]
}

# --- one file -----------------------------------------------------------------

# Findings on stdout, status 1 when there is at least one.
check_file() {
    local file=$1 line_number=0 line findings=0
    local logical="" first_line=0

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))

        if [ "${#line}" -gt "$MAX_COLUMNS" ]; then
            echo "$file:$line_number: ${#line} columns, the limit is $MAX_COLUMNS"
            findings=$((findings + 1))
        fi

        if [[ $line =~ ^[[:space:]]*# ]] || [[ $line =~ $LITERAL_MARKER ]]; then
            logical=""
            continue
        fi

        if [ -z "$logical" ]; then
            first_line=$line_number
        fi

        logical+=$line

        if continues_on_the_next_line "$line"; then
            logical=${logical%\\}
            continue
        fi

        report_shape_findings "$file" "$first_line" "$logical"
        findings=$((findings + SHAPE_FINDINGS))
        logical=""
    done < "$file"

    if [ -n "$logical" ]; then
        report_shape_findings "$file" "$first_line" "$logical"
        findings=$((findings + SHAPE_FINDINGS))
    fi

    [ "$findings" -eq 0 ]
}

# continues_on_the_next_line <line>: ends in an odd number of backslashes.
continues_on_the_next_line() {
    local line=$1 trailing

    trailing=${line##*[!\\]}
    [ $((${#trailing} % 2)) -eq 1 ]
}

# report_shape_findings <file> <first line> <logical line>: the findings of the
# shape rules on one logical line, one per line; their count in SHAPE_FINDINGS.
SHAPE_FINDINGS=0
report_shape_findings() {
    local file=$1 first_line=$2 line=$3
    local i count=0

    for i in "${!RULE_PATTERNS[@]}"; do
        if [ "$i" -eq "$AND_OR_INDEX" ] && opens_a_condition "$line"; then
            continue
        fi

        if [ "$i" -eq "$ASSIGNED_PIPELINE_INDEX" ] \
            && { [[ $line =~ $CARRIES_OR_TRUE ]] || opens_a_condition "$line"; }; then
            continue
        fi

        if [[ $line =~ ${RULE_PATTERNS[$i]} ]]; then
            echo "$file:$first_line: ${RULE_NAMES[$i]}"
            count=$((count + 1))
        fi
    done

    SHAPE_FINDINGS=$count
}

check_files() {
    local file files=0 files_with_findings=0 output count findings=0

    for file in "$@"; do
        if [ ! -f "$file" ] || [ ! -r "$file" ]; then
            echo "check-form: not a readable file: $file" >&2
            return 1
        fi

        files=$((files + 1))

        if output=$(check_file "$file"); then
            continue
        fi

        printf '%s\n' "$output"
        files_with_findings=$((files_with_findings + 1))
        count=$(wc -l <<< "$output")
        findings=$((findings + count))
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
# other, and each other known-bad input is refused for its own reason.

self_test_failed() {
    echo "check-form: self-test: $*" >&2
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

lines=$(grep -c x file 2> /dev/null || true)
echo "${lines:-0} line(s)"
words=$(grep x file | tr '\n' ' ' || true)
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
    'x=$(cat f || echo none)'          # form: literal
    'x=$(ls d | head -n1)'             # form: literal
    'x=$((n + $(wc -l < f)))'          # form: literal
)

self_test() {
    local dir i bad output long_line grep_continued echo_continued at_eof after_literal

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
            self_test_failed "rule $((i + 1)) missed its line: ${BAD_LINES[$i]}" "$output"
        fi

        if [ "$(grep -c "^$bad:" <<< "$output")" -ne 1 ]; then
            self_test_failed "rule $((i + 1))'s line hit more than one rule:" "$output"
        fi
    done

    grep_continued='x=$(grep a f %s\n    | tr x y)'     # form: literal
    echo_continued='y=$(grep b f %s\n    || echo none)' # form: literal
    printf "#!/usr/bin/env bash\n$grep_continued\n$echo_continued\n" '\' '\' > "$dir/continued.sh"
    output=$(check_files "$dir/continued.sh" || true)

    if ! grep -qF "$dir/continued.sh:2: ${RULE_NAMES[8]}" <<< "$output" \
        || ! grep -qF "$dir/continued.sh:4: ${RULE_NAMES[7]}" <<< "$output"; then
        self_test_failed "a shape spread over a continuation passed:" "$output"
    fi

    at_eof='x=$(grep a f | tr x y) %s' # form: literal
    printf "#!/usr/bin/env bash\n$at_eof" '\' > "$dir/eof.sh"
    output=$(check_files "$dir/eof.sh" || true)

    if ! grep -qF "$dir/eof.sh:2: ${RULE_NAMES[8]}" <<< "$output"; then
        self_test_failed "a shape on a file's last line, continued, passed:" "$output"
    fi

    after_literal='if true %s\nx=1 # form: literal\n%s\n' # form: literal
    printf "#!/usr/bin/env bash\n$after_literal" '\' "${BAD_LINES[2]}" > "$dir/literal.sh"
    output=$(check_files "$dir/literal.sh" || true)

    if ! grep -qF "$dir/literal.sh:4: ${RULE_NAMES[2]}" <<< "$output"; then
        self_test_failed "a literal line inside a continuation hid the next line:" "$output"
    fi

    printf '#!/usr/bin/env bash\necho a%s\n%s\n' '\\' "${BAD_LINES[8]}" > "$dir/escaped.sh"
    output=$(check_files "$dir/escaped.sh" || true)

    if ! grep -qF "$dir/escaped.sh:3: ${RULE_NAMES[8]}" <<< "$output"; then
        self_test_failed "an escaped backslash was read as a continuation:" "$output"
    fi

    # Known-bad: the literal marker matched any trailing comment, so a banned
    # shape with a plain comment after it passed.
    printf '#!/usr/bin/env bash\n%s # a plain comment\n' "${BAD_LINES[2]}" > "$dir/commented.sh"
    output=$(check_files "$dir/commented.sh" || true)

    if ! grep -qF "$dir/commented.sh:2: ${RULE_NAMES[2]}" <<< "$output"; then
        self_test_failed "a banned shape with a plain trailing comment passed:" "$output"
    fi

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

    output=$(check_files "$dir" 2>&1 || true)

    if ! grep -q "^check-form: not a readable file: $dir" <<< "$output"; then
        self_test_failed "a directory was not refused by name:" "$output"
    fi

    echo "self-test ok: 1 clean file, ${#BAD_LINES[@]} banned shapes each caught once," \
        "2 continued shapes caught at their first line, a continuation at EOF, after a" \
        "literal and an escaped backslash read right, a plain trailing comment no escape," \
        "2 long lines caught, a directory refused"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    "")
        echo "check-form: usage: check-form.sh <file>... | --self-test" >&2
        exit 1
        ;;
    *)
        check_files "$@"
        ;;
esac
