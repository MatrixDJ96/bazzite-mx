#!/usr/bin/env bash
# Kernel-module helpers shared by the kmod-builder stage and 50-kmods.sh:
# both must agree on the image's one kernel and on what a good module looks
# like. Needs log.sh for die.

# kernel_version [<modules-dir>]: the one kernel under /usr/lib/modules; two
# or none is a build error, because a module built for another kernel would
# never load. Counted as an array: to wc a here-string of nothing is one line,
# and an empty tree passed as a kernel named "".
kernel_version() {
    local dir=${1:-/usr/lib/modules} kvers
    mapfile -t kvers < <(ls "$dir" 2> /dev/null)
    [ "${#kvers[@]}" -eq 1 ] || die "expected one kernel under $dir, found ${#kvers[@]}: ${kvers[*]}"
    echo "${kvers[0]}"
}

# assert_module <file.ko> <kver> [<version>]: a readable module stamped for
# <kver> and, when <version> is given, carrying it. A vermagic mismatch means
# the kernel-devel tree and the installed kernel disagree (docs/gotchas.md).
assert_module() {
    local ko=$1 kver=$2 version=${3:-} vermagic got
    modinfo "$ko" > /dev/null 2>&1 || {
        echo "FAIL: $ko is not a readable kernel module" >&2
        return 1
    }
    vermagic=$(modinfo -F vermagic "$ko")
    case "$vermagic" in
        "$kver "*) ;;
        *)
            echo "FAIL: $ko vermagic '$vermagic' does not name kernel $kver" >&2
            return 1
            ;;
    esac
    if [ -n "$version" ]; then
        got=$(modinfo -F version "$ko")
        [ "$got" = "$version" ] || {
            echo "FAIL: $ko version '$got', expected $version" >&2
            return 1
        }
    fi
}
