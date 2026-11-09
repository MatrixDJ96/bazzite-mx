#!/usr/bin/env bash
# Builds one out-of-tree module per build_files/kmods/<name>/source.env into
# $OUT/<kver>/updates/, after preparing the BTF inputs: vmlinux extracted from
# the kernel image, pahole built from the tag CONFIG_PAHOLE_VERSION names.
#
# Usage: build-kmods.sh              build every module (the kmod-builder stage)
#        build-kmods.sh --self-test  assert_module, kernel_version and
#                                    source_ref on known inputs, the base's
#                                    in-tree msi-ec as the positive control
# Writes: /out/<kver>/updates/<KO_NAME>.ko per module, stripped of debug info
#   with its BTF kept, one source.env of this directory per module, pinned to a
#   COMMIT or following a TAG.
# Exit status: 0 done; 1 on a `FAIL: …` line or a usage error.
set -euo pipefail

HERE=$(dirname "$(realpath "$0")")
# shellcheck source=../lib/log.sh
source "$HERE/../lib/log.sh"
# shellcheck source=../lib/kmod.sh
source "$HERE/../lib/kmod.sh"
# shellcheck source=../lib/repos.sh
source "$HERE/../lib/repos.sh"

KMODS_DIR=$HERE
OUT=/out
SOURCES=/tmp/kmods-src
PAHOLE_URL=https://git.kernel.org/pub/scm/devel/pahole/pahole.git

# --- BTF ----------------------------------------------------------------------

# kbuild writes BTF with pahole against vmlinux and warns on a pahole other
# than the CONFIG_PAHOLE_VERSION release; the base ships neither and Fedora
# not every release. Warnings silenced as vendor code. Sets PAHOLE.
prepare_btf() {
    local kernel=$1
    local kernel_source=$2
    local wanted tag dir=$SOURCES/pahole

    "$kernel_source/scripts/extract-vmlinux" "/usr/lib/modules/$kernel/vmlinuz" \
        > "$kernel_source/vmlinux"

    wanted=$(sed -n 's/^CONFIG_PAHOLE_VERSION=//p' "$kernel_source/.config")
    tag=v$((wanted / 100)).$((wanted % 100))
    # The image stage's 00-prep.sh never runs here, so the strict value rides on the call.
    dnf_retry -y --setopt=skip_if_unavailable=False install \
        cmake elfutils-devel zlib-devel libbpf-devel
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" fetch -q --depth 1 "$PAHOLE_URL" "refs/tags/$tag"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
    cmake -Wno-deprecated -S "$dir" -B "$dir/build" -DCMAKE_BUILD_TYPE=Release \
        -DLIBBPF_EMBEDDED=OFF -DCMAKE_C_FLAGS=-w
    cmake --build "$dir/build" -j "$(nproc)"
    PAHOLE=$dir/build/pahole
    log "btf: pahole $tag built, the kernel's release"
}

# --- one module ---------------------------------------------------------------

# Sets URL, COMMIT or TAG, KO_NAME, KO_BUILD_PATH, KO_VERSION and
# KO_BUILD_ARGS from <source.env>.
read_source_env() {
    local source_env=$1

    unset URL COMMIT TAG KO_NAME KO_BUILD_PATH KO_VERSION KO_BUILD_ARGS
    # shellcheck disable=SC1090
    source "$source_env"
}

# The ref to fetch: COMMIT, a pin, or refs/tags/TAG, followed; one of the two,
# never both.
source_ref() {
    local name=$1

    if [ -n "${COMMIT:-}" ] && [ -z "${TAG:-}" ]; then
        echo "$COMMIT"
    elif [ -n "${TAG:-}" ] && [ -z "${COMMIT:-}" ]; then
        echo "refs/tags/$TAG"
    else
        fail_build "$name: source.env sets COMMIT '${COMMIT:-}' and TAG '${TAG:-}'," \
            "exactly one is required"
    fi
}

# A fetch into <dir>; a pin is checked to be what landed, a tag's commit is
# recorded in COMMIT for the log.
fetch_source() {
    local name=$1
    local dir=$2
    local ref checked_out

    ref=$(source_ref "$name")
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" fetch -q --depth 1 "$URL" "$ref"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD

    checked_out=$(git -C "$dir" rev-parse HEAD)

    if [ -n "${TAG:-}" ]; then
        COMMIT=$checked_out
    elif [ "$checked_out" != "$COMMIT" ]; then
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
    make -C "$kernel_source" M="$dir" PAHOLE="$PAHOLE" modules ${KO_BUILD_ARGS:-}

    if [ ! -f "$dir/$KO_BUILD_PATH" ]; then
        fail_build "$name: $KO_BUILD_PATH not produced by the build"
    fi
}

# Staged bare: the base ships its in-tree modules uncompressed.
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
        "version '${KO_VERSION:-}'," \
        "commit $COMMIT${TAG:+ (tag $TAG)}${KO_BUILD_ARGS:+, make args '$KO_BUILD_ARGS'}"
}

# --- the build ----------------------------------------------------------------

build_all() {
    local kernel kernel_source source_env name dir built=0

    kernel=$(kernel_version)
    kernel_source=/usr/src/kernels/$kernel

    if [ ! -f "$kernel_source/Makefile" ] || [ ! -f "$kernel_source/Module.symvers" ]; then
        fail_build "$kernel_source is not a kernel build tree"
    fi

    group "btf"
    prepare_btf "$kernel" "$kernel_source"
    endgroup

    for source_env in "$KMODS_DIR"/*/source.env; do
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

# A pin and a tag each give their ref; both or neither is refused.
self_test_source_ref() {
    if [ "$(COMMIT=abc TAG='' source_ref t)" != abc ] \
        || [ "$(COMMIT='' TAG=b source_ref t)" != refs/tags/b ]; then
        fail_build "self-test: a pin or a tag did not give its ref"
    fi

    if (COMMIT=abc TAG=b source_ref t) > /dev/null 2>&1; then
        fail_build "self-test: COMMIT and TAG together passed"
    fi

    if (COMMIT='' TAG='' source_ref t) > /dev/null 2>&1; then
        fail_build "self-test: neither COMMIT nor TAG passed"
    fi
}

self_test() {
    local kernel

    kernel=$(kernel_version)
    self_test_assert_module "$kernel"
    self_test_kernel_version
    self_test_source_ref

    echo "self-test ok: 1 good module, 2 refs given, 7 bad inputs refused"
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
