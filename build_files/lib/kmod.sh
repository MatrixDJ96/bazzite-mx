#!/usr/bin/env bash
# The kernel helper of tests 21 and 22: they must agree on the image's one
# kernel. Needs lib/log.sh for fail_build.

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
