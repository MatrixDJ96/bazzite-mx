#!/usr/bin/env bash
# Builds one out-of-tree module per build_files/kmods/<name>/source.env into
# $OUT/<kver>/updates/. The kmod-builder stage runs FROM the base image, which
# already carries kernel-devel for its own kernel and the toolchain.
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
        unset URL COMMIT KO_NAME KO_BUILD_PATH KO_VERSION KO_BUILD_ARGS
        # shellcheck disable=SC1090
        source "$env"
        [[ ${COMMIT:-} =~ ^[0-9a-f]{40}$ ]] || die "$env: COMMIT must be a full commit id"
        : "${URL:?$env: URL missing}" "${KO_NAME:?$env: KO_NAME missing}" "${KO_BUILD_PATH:?$env: KO_BUILD_PATH missing}"
        src=/tmp/kmods-src/$name
        rm -rf "$src"
        mkdir -p "$src"
        # A fetch by commit id, so the pin is what lands, checked afterwards.
        git -C "$src" init -q
        git -C "$src" fetch -q --depth 1 "$URL" "$COMMIT"
        git -C "$src" -c advice.detachedHead=false checkout -q FETCH_HEAD
        [ "$(git -C "$src" rev-parse HEAD)" = "$COMMIT" ] || die "$name: checkout is $(git -C "$src" rev-parse HEAD), not $COMMIT"
        # The kernel's build system against the target tree, never a module's
        # own `make`: that hardcodes /lib/modules/$(uname -r)/build, which in
        # a build is the runner's kernel and not the image's.
        # shellcheck disable=SC2086  # KO_BUILD_ARGS is a list of VAR=value words
        make -C "$ksrc" M="$src" modules ${KO_BUILD_ARGS:-}
        ko=$src/$KO_BUILD_PATH
        [ -f "$ko" ] || die "$name: $KO_BUILD_PATH not produced by the build"
        # What `make modules_install INSTALL_MOD_STRIP=1` does. The .ko is
        # staged bare: the base ships its in-tree modules uncompressed.
        strip --strip-debug "$ko"
        staged=$OUT/$kver/updates/$KO_NAME.ko
        install -Dm644 "$ko" "$staged"
        assert_module "$staged" "$kver" "${KO_VERSION:-}" || exit 1
        log "kmod $name: $KO_NAME.ko for $kver, $(stat -c %s "$staged") bytes, version '${KO_VERSION:-}', commit $COMMIT${KO_BUILD_ARGS:+, make args '$KO_BUILD_ARGS'}"
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
