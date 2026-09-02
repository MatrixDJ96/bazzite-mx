#!/usr/bin/env bash
# Kernel-module helpers shared by the kmod-builder stage, 50-kmods.sh, its
# test and tests 21 and 22: all must agree on the
# image's one kernel and on what a good module looks like. Needs lib/log.sh for fail_build.

# The one kernel under <modules-dir>; two or none is a build error, because a
# module built for another kernel would never load.
kernel_version() {
    local dir=${1:-/usr/lib/modules} kernels

    mapfile -t kernels < <(ls "$dir" 2> /dev/null)

    if [ "${#kernels[@]}" -ne 1 ]; then
        fail_build "expected one kernel under $dir, found ${#kernels[@]}: ${kernels[*]}"
    fi

    echo "${kernels[0]}"
}

# Status 0 for a readable module stamped for <kver> and, when <version> is
# given, carrying it. A vermagic mismatch means the kernel-devel tree and the
# installed kernel disagree.
assert_module() {
    local ko=$1 kver=$2 version=${3:-} vermagic found

    vermagic=$(modinfo -F vermagic "$ko")

    if [[ $vermagic != "$kver "* ]]; then
        echo "FAIL: $ko vermagic '$vermagic' does not name kernel $kver" >&2
        return 1
    fi

    if [ -n "$version" ]; then
        found=$(modinfo -F version "$ko")

        if [ "$found" != "$version" ]; then
            echo "FAIL: $ko version '$found', expected $version" >&2
            return 1
        fi
    fi
}
