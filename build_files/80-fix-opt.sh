#!/usr/bin/env bash
# Payload under /opt moves to /usr/lib/opt, because /opt is a symlink to
# var/opt and 95-clean-stage.sh wipes /var. A tmpfiles.d line per name puts
# the /var/opt/<name> symlink back at boot, so baked-in paths keep resolving.
#
# Usage: 80-fix-opt.sh              run by build.sh, no arguments
#        80-fix-opt.sh --self-test  the move on fixture trees, `self-test ok: …`
#                                   when the good layout moves and three bad
#                                   ones are refused
# Writes: /usr/lib/opt/<name> per directory under /var/opt, and
#   /usr/lib/tmpfiles.d/bazzite-mx-opt.conf with one `L+` line per name.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

VAR_OPT=/var/opt
LIB_OPT=/usr/lib/opt
TMPFILES_CONF=/usr/lib/tmpfiles.d/bazzite-mx-opt.conf

# --- the move -----------------------------------------------------------------

# Prints every entry under <dir>, hidden ones included, one per line.
entries_of() {
    local dir=$1
    local entry

    for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        if [ -e "$entry" ] || [ -L "$entry" ]; then
            echo "$entry"
        fi
    done
}

# One `FAIL: …` line per entry of <var-opt> that must not move: a file or a
# link, or a name already taken under <lib-opt>. Status 1 when any is found.
check_entries() {
    local var_opt=$1
    local lib_opt=$2
    local entry name failed=0

    while IFS= read -r entry; do
        name=$(basename "$entry")

        if [ -L "$entry" ] || [ ! -d "$entry" ]; then
            echo "FAIL: $entry is not a directory (a package left a file or link under /opt)"
            failed=1
        elif [ -e "$lib_opt/$name" ] || [ -L "$lib_opt/$name" ]; then
            echo "FAIL: $lib_opt/$name already exists"
            failed=1
        fi
    done < <(entries_of "$var_opt")

    return "$failed"
}

# Moves every directory under <var-opt> to <lib-opt> and writes one tmpfiles
# line per name to <conf>. Every entry is checked before the first move, so
# a bad layout returns 1 having moved nothing. Prints one line per finding
# or move.
relocate_opt() {
    local var_opt=$1
    local lib_opt=$2
    local conf=$3
    local entry name names=()

    if [ ! -d "$var_opt" ]; then
        echo "nothing under $var_opt"
        return 0
    fi

    if ! check_entries "$var_opt" "$lib_opt"; then
        return 1
    fi

    while IFS= read -r entry; do
        names+=("$(basename "$entry")")
    done < <(entries_of "$var_opt")

    if [ ${#names[@]} -eq 0 ]; then
        echo "nothing under $var_opt"
        return 0
    fi

    mkdir -p "$lib_opt" "$(dirname "$conf")"

    for name in "${names[@]}"; do
        mv "$var_opt/$name" "$lib_opt/$name"
        echo "moved $var_opt/$name to $lib_opt/$name"
    done

    for name in "${names[@]}"; do
        echo "L+ /var/opt/$name - - - - /usr/lib/opt/$name"
    done > "$conf.new"
    mv -f "$conf.new" "$conf"

    echo "${#names[@]} tmpfiles line(s) in $conf"
}

# --- the self-test ------------------------------------------------------------

# Runs the move on the fixture tree <dir>, output to <dir>/out.
self_test_run() {
    local dir=$1

    relocate_opt "$dir/var/opt" "$dir/usr/lib/opt" "$dir/usr/lib/tmpfiles.d/opt.conf" \
        > "$dir/out" 2>&1
}

# The layout <what> must be refused with the message <message>, and the good
# directory beside it must not have moved.
self_test_expect_fail() {
    local dir=$1
    local what=$2
    local message=$3

    if self_test_run "$dir"; then
        fail_build "self-test: '$what' passed"
    fi

    if ! grep -q "FAIL: $message" "$dir/out"; then
        fail_build "self-test: '$what' failed for another reason: $(cat "$dir/out")"
    fi

    if [ ! -d "$dir/var/opt/Good" ]; then
        fail_build "self-test: '$what' moved a directory before failing"
    fi

    echo "self-test: caught $what"
}

self_test_good_layout() {
    local dir=$1
    local conf=$dir/usr/lib/tmpfiles.d/opt.conf
    local expected_lines

    mkdir -p "$dir/var/opt/Good/bin" "$dir/var/opt/Other" "$dir/usr/lib/opt"
    : > "$dir/var/opt/Good/bin/app"

    if ! self_test_run "$dir"; then
        fail_build "self-test: the known-good layout fails: $(cat "$dir/out")"
    fi

    if [ ! -f "$dir/usr/lib/opt/Good/bin/app" ]; then
        fail_build "self-test: payload not moved"
    fi

    if [ -n "$(ls -A "$dir/var/opt")" ]; then
        fail_build "self-test: $dir/var/opt not empty after the move"
    fi

    expected_lines="L+ /var/opt/Good - - - - /usr/lib/opt/Good
L+ /var/opt/Other - - - - /usr/lib/opt/Other"

    if [ "$(cat "$conf")" != "$expected_lines" ]; then
        fail_build "self-test: tmpfiles lines: $(cat "$conf")"
    fi

    echo "self-test: known-good layout moves 2 directories"
}

self_test_bad_layouts() {
    local dir=$1

    rm -rf "$dir/usr/lib/opt" "$dir/usr/lib/tmpfiles.d"
    mkdir -p "$dir/var/opt/Good" "$dir/usr/lib/opt/Good"
    self_test_expect_fail "$dir" "namesake under /usr/lib/opt" \
        "$dir/usr/lib/opt/Good already exists"
    rm -rf "$dir/usr/lib/opt/Good"

    : > "$dir/var/opt/stray.txt"
    self_test_expect_fail "$dir" "file under /var/opt" "$dir/var/opt/stray.txt is not a directory"
    rm "$dir/var/opt/stray.txt"

    ln -s /usr/lib/opt/Good "$dir/var/opt/.hidden"
    self_test_expect_fail "$dir" "symlink under /var/opt" "$dir/var/opt/.hidden is not a directory"
    rm "$dir/var/opt/.hidden"
}

self_test_missing_var_opt() {
    local dir=$1

    rm -rf "$dir/var/opt"

    if ! self_test_run "$dir"; then
        fail_build "self-test: a missing /var/opt fails: $(cat "$dir/out")"
    fi

    if ! grep -q '^nothing under' "$dir/out"; then
        fail_build "self-test: missing /var/opt not reported as empty"
    fi

    echo "self-test: missing /var/opt is a no-op"
}

self_test() {
    local dir

    dir=$(mktemp -d)
    # shellcheck disable=SC2064  # expand now: the local is gone at EXIT
    trap "rm -rf '$dir'" EXIT

    self_test_good_layout "$dir"
    self_test_bad_layouts "$dir"
    self_test_missing_var_opt "$dir"

    echo "self-test ok: 1 good layout, 3 bad layouts refused"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    "")
        if ! relocate_opt "$VAR_OPT" "$LIB_OPT" "$TMPFILES_CONF"; then
            fail_build "fix-opt: $VAR_OPT holds something this script will not move"
        fi

        if [ -n "$(ls -A "$VAR_OPT" 2> /dev/null)" ]; then
            fail_build "fix-opt: $VAR_OPT not empty after the move"
        fi

        log "fix-opt: $VAR_OPT relocated to $LIB_OPT"
        ;;
    *)
        fail_build "usage: 80-fix-opt.sh [--self-test]"
        ;;
esac
