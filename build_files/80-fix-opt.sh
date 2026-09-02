#!/usr/bin/env bash
# Payload under /opt moves to /usr/lib/opt, because /opt is a symlink to
# var/opt and 95-clean-stage.sh wipes /var. A tmpfiles.d line per name puts
# the /var/opt/<name> symlink back at boot, so baked-in paths keep resolving.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

# relocate_opt <var-opt> <lib-opt> <tmpfiles-conf>: every entry is checked
# before the first move, so a bad layout returns 1 having moved nothing.
# Prints one line per finding or move.
relocate_opt() {
    local var_opt=$1 lib_opt=$2 conf=$3
    local entry name failed=0 names=()
    if [ ! -d "$var_opt" ]; then
        echo "nothing under $var_opt"
        return 0
    fi
    for entry in "$var_opt"/* "$var_opt"/.[!.]* "$var_opt"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        name=$(basename "$entry")
        if [ -L "$entry" ] || [ ! -d "$entry" ]; then
            echo "FAIL: $entry is not a directory (a package left a file or link under /opt)"
            failed=1
        elif [ -e "$lib_opt/$name" ] || [ -L "$lib_opt/$name" ]; then
            echo "FAIL: $lib_opt/$name already exists"
            failed=1
        else
            names+=("$name")
        fi
    done
    [ "$failed" -eq 0 ] || return 1
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

self_test() {
    local t
    t=$(mktemp -d)
    # shellcheck disable=SC2064  # expand now: the local is gone at EXIT
    trap "rm -rf '$t'" EXIT
    run() { relocate_opt "$t/var/opt" "$t/usr/lib/opt" "$t/usr/lib/tmpfiles.d/opt.conf" > "$t/out" 2>&1; }
    expect_fail() {
        if run; then die "self-test: '$1' passed"; fi
        grep -q "FAIL: $2" "$t/out" || die "self-test: '$1' failed for another reason: $(cat "$t/out")"
        [ -d "$t/var/opt/Good" ] || die "self-test: '$1' moved a directory before failing"
        echo "self-test: caught $1"
    }

    mkdir -p "$t/var/opt/Good/bin" "$t/var/opt/Other" "$t/usr/lib/opt"
    : > "$t/var/opt/Good/bin/app"
    run || die "self-test: the known-good layout fails: $(cat "$t/out")"
    [ -x "$t/usr/lib/opt/Good/bin/app" ] || [ -f "$t/usr/lib/opt/Good/bin/app" ] || die "self-test: payload not moved"
    [ -z "$(ls -A "$t/var/opt")" ] || die "self-test: $t/var/opt not empty after the move"
    [ "$(cat "$t/usr/lib/tmpfiles.d/opt.conf")" = "L+ /var/opt/Good - - - - /usr/lib/opt/Good
L+ /var/opt/Other - - - - /usr/lib/opt/Other" ] || die "self-test: tmpfiles lines: $(cat "$t/usr/lib/tmpfiles.d/opt.conf")"
    echo "self-test: known-good layout moves 2 directories"

    rm -rf "$t/usr/lib/opt" "$t/usr/lib/tmpfiles.d"
    mkdir -p "$t/var/opt/Good" "$t/usr/lib/opt/Good"
    expect_fail "namesake under /usr/lib/opt" "$t/usr/lib/opt/Good already exists"
    rm -rf "$t/usr/lib/opt/Good"

    : > "$t/var/opt/stray.txt"
    expect_fail "file under /var/opt" "$t/var/opt/stray.txt is not a directory"
    rm "$t/var/opt/stray.txt"

    ln -s /usr/lib/opt/Good "$t/var/opt/.hidden"
    expect_fail "symlink under /var/opt" "$t/var/opt/.hidden is not a directory"
    rm "$t/var/opt/.hidden"

    rm -rf "$t/var/opt"
    run || die "self-test: a missing /var/opt fails: $(cat "$t/out")"
    grep -q '^nothing under' "$t/out" || die "self-test: missing /var/opt not reported as empty"
    echo "self-test: missing /var/opt is a no-op"

    echo "self-test ok: 1 good layout, 3 bad layouts refused"
}

case "${1:-}" in
    --self-test) self_test ;;
    "")
        relocate_opt /var/opt /usr/lib/opt /usr/lib/tmpfiles.d/bazzite-mx-opt.conf || die "fix-opt: /var/opt holds something this script will not move"
        [ -z "$(ls -A /var/opt 2> /dev/null)" ] || die "fix-opt: /var/opt not empty after the move"
        log "fix-opt: /var/opt relocated to /usr/lib/opt"
        ;;
    *) die "usage: 80-fix-opt.sh [--self-test]" ;;
esac
