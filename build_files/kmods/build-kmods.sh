#!/usr/bin/env bash
# Out-of-tree kernel modules, built in the Containerfile's kmod-builder stage
# (FROM the base image itself: it already ships kernel-devel for its own
# kernel, versionlocked by bazzite install-kernel-akmods:30-32, plus gcc,
# make, binutils, elfutils-libelf-devel and git-core; MEASURED 2026-09-02 on
# 7.2.1-ogc4.1, so no akmods carrier stage and no package install is needed).
# For each build_files/kmods/<name>/source.env: fetch the pinned commit,
# build against /usr/src/kernels/<kver>, strip the debug sections the way
# `make modules_install INSTALL_MOD_STRIP=1` does (scripts/Makefile.modinst:
# 76-85, --strip-debug), stage the bare .ko under $OUT/<kver>/updates/ (the
# base ships its in-tree modules uncompressed: CONFIG_MODULE_COMPRESS_ALL
# unset, MEASURED) and assert it is a readable module stamped for that kernel
# (vermagic) with the expected MODULE_VERSION (lib/kmod.sh, shared with
# 50-kmods.sh, which installs the staged files into the image and runs
# depmod).
#
#   build-kmods.sh              build every module (KMODS_DIR, OUT overridable)
#   build-kmods.sh --self-test  prove assert_module refuses a wrong kernel, a
#                               wrong version and a file that is no module
set -euo pipefail

HERE=$(dirname "$(realpath "$0")")
# shellcheck source=../lib/log.sh
source "$HERE/../lib/log.sh"
# shellcheck source=../lib/kmod.sh
source "$HERE/../lib/kmod.sh"

KMODS_DIR=${KMODS_DIR:-$HERE}
OUT=${OUT:-/out}

build_all() {
    local kver ksrc env name src ko staged n=0
    kver=$(kernel_version)
    ksrc=/usr/src/kernels/$kver
    [ -f "$ksrc/Makefile" ] && [ -f "$ksrc/Module.symvers" ] || die "$ksrc is not a kernel build tree"
    for env in "$KMODS_DIR"/*/source.env; do
        [ -e "$env" ] || die "no */source.env under $KMODS_DIR"
        name=$(basename "$(dirname "$env")")
        group "kmod $name"
        unset URL COMMIT KO_NAME KO_BUILD_PATH KO_VERSION
        # shellcheck disable=SC1090
        source "$env"
        [[ ${COMMIT:-} =~ ^[0-9a-f]{40}$ ]] || die "$env: COMMIT must be a full commit id"
        : "${URL:?$env: URL missing}" "${KO_NAME:?$env: KO_NAME missing}" "${KO_BUILD_PATH:?$env: KO_BUILD_PATH missing}"
        src=/tmp/kmods-src/$name
        rm -rf "$src"
        mkdir -p "$src"
        # Fetch exactly the pinned commit (GitHub serves any reachable commit
        # by id) and prove the checkout is that commit.
        git -C "$src" init -q
        git -C "$src" fetch -q --depth 1 "$URL" "$COMMIT"
        git -C "$src" -c advice.detachedHead=false checkout -q FETCH_HEAD
        [ "$(git -C "$src" rev-parse HEAD)" = "$COMMIT" ] || die "$name: checkout is $(git -C "$src" rev-parse HEAD), not $COMMIT"
        # The kernel's build system against the target tree, not the module's
        # own `make` (it hardcodes /lib/modules/$(uname -r)/build: the
        # builder's running kernel is the runner's, not the image's).
        make -C "$ksrc" M="$src" modules
        ko=$src/$KO_BUILD_PATH
        [ -f "$ko" ] || die "$name: $KO_BUILD_PATH not produced by the build"
        strip --strip-debug "$ko"
        staged=$OUT/$kver/updates/$KO_NAME.ko
        install -Dm644 "$ko" "$staged"
        assert_module "$staged" "$kver" "${KO_VERSION:-}" || exit 1
        log "kmod $name: $KO_NAME.ko for $kver, $(stat -c %s "$staged") bytes, version '${KO_VERSION:-}', commit $COMMIT"
        n=$((n + 1))
        endgroup
    done
    [ "$n" -gt 0 ] || die "no module built"
    log "build-kmods: $n module(s) staged under $OUT/$kver/updates"
}

self_test() {
    local kver intree
    kver=$(kernel_version)
    # The base's own in-tree msi-ec is the positive control.
    intree=/usr/lib/modules/$kver/kernel/drivers/platform/x86/msi-ec.ko
    [ -f "$intree" ] || die "self-test: $intree missing"
    assert_module "$intree" "$kver" 2> /dev/null || die "self-test: the in-tree module fails its own kernel"
    if assert_module "$intree" "0.0.0-none.fc44.x86_64" 2> /dev/null; then
        die "self-test: a wrong kernel passed"
    fi
    if assert_module "$intree" "$kver" "9.9" 2> /dev/null; then
        die "self-test: a wrong version passed"
    fi
    if assert_module /etc/os-release "$kver" 2> /dev/null; then
        die "self-test: a file that is no module passed"
    fi
    # The kernel count seen red: an empty tree and a two-kernel tree.
    local guard
    guard=$(mktemp -d)
    mkdir -p "$guard/none" "$guard/two/a" "$guard/two/b"
    if (kernel_version "$guard/none") > /dev/null 2>&1; then
        die "self-test: an empty modules tree passed as one kernel"
    fi
    if (kernel_version "$guard/two") > /dev/null 2>&1; then
        die "self-test: two kernels passed as one"
    fi
    rm -rf "$guard"
    echo "self-test ok: 1 good module, 5 bad inputs refused"
}

case "${1:-}" in
    --self-test) self_test ;;
    "") build_all ;;
    *)
        echo "usage: build-kmods.sh [--self-test]" >&2
        exit 1
        ;;
esac
