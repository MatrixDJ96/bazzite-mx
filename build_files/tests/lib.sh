#!/usr/bin/env bash
# Checks the smoke tests share. Each prints exactly one `OK: …` or `FAIL: …`
# line per item, the contract tests/run.sh reads. Sourced by the tests that
# need them.

# on_one_line <fallback> [<separator>]: stdin on one line, the separator (a
# blank) between its lines, or the fallback when stdin is empty. A FAIL line
# built with it never ends blank, whatever the probe read.
on_one_line() {
    local fallback=$1 separator=${2:- }
    local text

    text=$(tr '\n' "$separator" || true)
    text=${text%"$separator"}
    printf '%s' "${text:-$fallback}"
}

# check_unit_state [--global] <unit> <expected> [<note>]
check_unit_state() {
    local scope="" unit expected note state

    if [ "$1" = --global ]; then
        scope=--global
        shift
    fi

    unit=$1
    expected=$2
    note=${3:+ ($3)}
    state=$(systemctl ${scope:+"$scope"} is-enabled "$unit" 2> /dev/null || true)

    if [ "$state" = "$expected" ]; then
        echo "OK: $unit${scope:+ (global)} $expected$note"
    else
        echo "FAIL: $unit${scope:+ (global)} is" \
            "${state:-without a state (unit missing or unreadable)}"
    fi
}

# check_self_test <label> <command>...: the command's --self-test exits 0 and
# ends with its `self-test ok` line, which the OK line carries; the FAIL line
# carries the whole output, on one line.
check_self_test() {
    local label=$1
    shift
    local output status

    if output=$("$@" --self-test 2>&1); then
        status=0
    else
        status=$?
    fi

    if [ "$status" -eq 0 ] && grep -q '^self-test ok' <<< "$output"; then
        echo "OK: $label self-test: $(tail -n1 <<< "$output")"
    else
        echo "FAIL: $label self-test (exit $status):" \
            "$(on_one_line 'no output' <<< "$output")"
    fi
}
