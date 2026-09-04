#!/usr/bin/env bash
# Builds one out-of-tree module per build_files/kmods/<name>/source.env into
# $OUT/<kver>/updates/. The kmod-builder stage runs FROM the base image, which
# already carries kernel-devel for its own kernel and the toolchain.
#
# Usage: build-kmods.sh              build every module (the kmod-builder stage)
#        build-kmods.sh --self-test  assert_module and kernel_version on known
#                                    inputs, the base's in-tree msi-ec as the
#                                    positive control
# Reads: KMODS_DIR (default: this directory), OUT (default /out).
# Writes: $OUT/<kver>/updates/<name>.ko per module, stripped of debug info.
# Exit status: 0 done; 1 on a `FAIL: …` line or a usage error.
set -euo pipefail

HERE=$(dirname "$(realpath "$0")")
# shellcheck source=../lib/log.sh
source "$HERE/../lib/log.sh"
# shellcheck source=../lib/kmod.sh
source "$HERE/../lib/kmod.sh"

KMODS_DIR=${KMODS_DIR:-$HERE}
OUT=${OUT:-/out}
SOURCES=/tmp/kmods-src

# --- one module ---------------------------------------------------------------

# Sets URL, COMMIT, KO_NAME, KO_BUILD_PATH, KO_VERSION and KO_BUILD_ARGS from
# <source.env>; the first four are required, COMMIT as a full commit id.
read_source_env() {
    local source_env=$1

    unset URL COMMIT KO_NAME KO_BUILD_PATH KO_VERSION KO_BUILD_ARGS
    # shellcheck disable=SC1090
    source "$source_env"

    if [[ ! ${COMMIT:-} =~ ^[0-9a-f]{40}$ ]]; then
        fail_build "$source_env: COMMIT must be a full commit id"
    fi

    if [ -z "${URL:-}" ]; then
        fail_build "$source_env: URL missing"
    fi

    if [ -z "${KO_NAME:-}" ]; then
        fail_build "$source_env: KO_NAME missing"
    fi

    if [ -z "${KO_BUILD_PATH:-}" ]; then
        fail_build "$source_env: KO_BUILD_PATH missing"
    fi
}

# A fetch by commit id into <dir>, so the pin is what lands, checked after.
fetch_source() {
    local name=$1
    local dir=$2
    local checked_out

    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" fetch -q --depth 1 "$URL" "$COMMIT"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD

    checked_out=$(git -C "$dir" rev-parse HEAD)

    if [ "$checked_out" != "$COMMIT" ]; then
        fail_build "$name: checkout is $checked_out, not $COMMIT"
    fi
}

# The kernel's build system against the target tree, never a module's own
# `make`: that hardcodes /lib/modules/$(uname -r)/build, which in a build is
# the runner's kernel and not the image's.
build_module() {
    local name=$1
    local dir=$2
    local kernel_source=$3

    # shellcheck disable=SC2086  # KO_BUILD_ARGS is a list of VAR=value words
    make -C "$kernel_source" M="$dir" modules ${KO_BUILD_ARGS:-}

    if [ ! -f "$dir/$KO_BUILD_PATH" ]; then
        fail_build "$name: $KO_BUILD_PATH not produced by the build"
    fi
}

# What `make modules_install INSTALL_MOD_STRIP=1` does. The .ko is staged
# bare: the base ships its in-tree modules uncompressed.
stage_module() {
    local name=$1
    local module_file=$2
    local kernel=$3
    local staged=$OUT/$kernel/updates/$KO_NAME.ko

    strip --strip-debug "$module_file"
    install -Dm644 "$module_file" "$staged"

    if ! assert_module "$staged" "$kernel" "${KO_VERSION:-}"; then
        exit 1
    fi

    log "kmod $name: $KO_NAME.ko for $kernel, $(stat -c %s "$staged") bytes," \
        "version '${KO_VERSION:-}', commit $COMMIT${KO_BUILD_ARGS:+, make args '$KO_BUILD_ARGS'}"
}

# --- the build ----------------------------------------------------------------

build_all() {
    local kernel kernel_source source_env name dir built=0

    kernel=$(kernel_version)
    kernel_source=/usr/src/kernels/$kernel

    if [ ! -f "$kernel_source/Makefile" ] || [ ! -f "$kernel_source/Module.symvers" ]; then
        fail_build "$kernel_source is not a kernel build tree"
    fi

    for source_env in "$KMODS_DIR"/*/source.env; do
        if [ ! -e "$source_env" ]; then
            fail_build "no */source.env under $KMODS_DIR"
        fi

        name=$(basename "$(dirname "$source_env")")
        dir=$SOURCES/$name
        group "kmod $name"

        read_source_env "$source_env"
        fetch_source "$name" "$dir"
        build_module "$name" "$dir" "$kernel_source"
        stage_module "$name" "$dir/$KO_BUILD_PATH" "$kernel"

        built=$((built + 1))
        endgroup
    done

    if [ "$built" -eq 0 ]; then
        fail_build "no module built"
    fi

    log "build-kmods: $built module(s) staged under $OUT/$kernel/updates"
}

# --- the self-test ------------------------------------------------------------

# The base's own in-tree msi-ec is the positive control; a wrong kernel, a
# wrong version and a file that is no module are refused.
self_test_assert_module() {
    local kernel=$1
    local in_tree=/usr/lib/modules/$kernel/kernel/drivers/platform/x86/msi-ec.ko

    if [ ! -f "$in_tree" ]; then
        fail_build "self-test: $in_tree missing"
    fi

    if ! assert_module "$in_tree" "$kernel" 2> /dev/null; then
        fail_build "self-test: the in-tree module fails its own kernel"
    fi

    if assert_module "$in_tree" "0.0.0-none.fc44.x86_64" 2> /dev/null; then
        fail_build "self-test: a wrong kernel passed"
    fi

    if assert_module "$in_tree" "$kernel" "9.9" 2> /dev/null; then
        fail_build "self-test: a wrong version passed"
    fi

    if assert_module /etc/os-release "$kernel" 2> /dev/null; then
        fail_build "self-test: a file that is no module passed"
    fi
}

# The kernel count seen red: an empty tree and a two-kernel tree.
self_test_kernel_version() {
    local trees

    trees=$(mktemp -d)
    mkdir -p "$trees/none" "$trees/two/a" "$trees/two/b"

    if (kernel_version "$trees/none") > /dev/null 2>&1; then
        fail_build "self-test: an empty modules tree passed as one kernel"
    fi

    if (kernel_version "$trees/two") > /dev/null 2>&1; then
        fail_build "self-test: two kernels passed as one"
    fi

    rm -rf "$trees"
}

self_test() {
    local kernel

    kernel=$(kernel_version)
    self_test_assert_module "$kernel"
    self_test_kernel_version

    echo "self-test ok: 1 good module, 5 bad inputs refused"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    "")
        build_all
        ;;
    *)
        echo "usage: build-kmods.sh [--self-test]" >&2
        exit 1
        ;;
esac
