#!/usr/bin/env bash
# Install the ORAS CLI from its own GitHub release, the tarball refused unless
# its sha256 matches the release's checksums file. Replaces setup-oras, which
# refuses any version newer than the list embedded in it (docs/gotchas.md).
#
#   install-oras.sh <version> <dir>    download, verify, extract oras into <dir>
#   install-oras.sh --self-test        FIXTURE_DIR stands in for the download
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

RELEASES=https://github.com/oras-project/oras/releases/download

fetch() {
    local version=$1 work=$2 f
    for f in "oras_${version}_linux_amd64.tar.gz" "oras_${version}_checksums.txt"; do
        if [ -n "${FIXTURE_DIR:-}" ]; then
            cp "$FIXTURE_DIR/$f" "$work/$f"
        else
            curl -fsSL --proto '=https' --retry 3 -o "$work/$f" "$RELEASES/v${version}/$f"
        fi
    done
}

verify() {
    local version=$1 work=$2 line tarball
    tarball="oras_${version}_linux_amd64.tar.gz"
    line=$(grep " ${tarball}\$" "$work/oras_${version}_checksums.txt" || true)
    [ -n "$line" ] || {
        err "no checksum line for $tarball"
        return 1
    }
    (cd "$work" && sha256sum -c --quiet - <<< "$line") || {
        err "checksum mismatch for $tarball"
        return 1
    }
    echo "checksum ok: $tarball"
}

install_oras() {
    local version=$1 dir=$2 work
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version '$version' is not X.Y.Z"
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    fetch "$version" "$work"
    verify "$version" "$work" || exit 1
    mkdir -p "$dir"
    tar -xzf "$work/oras_${version}_linux_amd64.tar.gz" -C "$dir" oras
    [ -x "$dir/oras" ] || fail "no oras binary in the tarball"
    echo "install-oras ok: $("$dir/oras" version | head -n1) in $dir"
}

self_test() {
    local dir
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    mkdir -p "$dir/fx" "$dir/w"
    printf 'oras' > "$dir/fx/oras_9.9.9_linux_amd64.tar.gz"
    printf '%s  oras_9.9.9_linux_amd64.tar.gz\n' "$(sha256sum "$dir/fx/oras_9.9.9_linux_amd64.tar.gz" | cut -d' ' -f1)" > "$dir/fx/oras_9.9.9_checksums.txt"
    FIXTURE_DIR=$dir/fx fetch 9.9.9 "$dir/w"
    verify 9.9.9 "$dir/w" > /dev/null || fail "self-test: a matching checksum refused"
    printf 'tampered' > "$dir/w/oras_9.9.9_linux_amd64.tar.gz"
    if verify 9.9.9 "$dir/w" > /dev/null 2>&1; then
        fail "self-test: a mismatching checksum accepted"
    fi
    sed -i 's/linux_amd64/linux_arm64/' "$dir/w/oras_9.9.9_checksums.txt"
    if verify 9.9.9 "$dir/w" > /dev/null 2>&1; then
        fail "self-test: a missing checksum line accepted"
    fi
    echo "self-test ok: 1 matching checksum accepted, 2 bad inputs refused"
}

case "${1:-}" in
    --self-test) self_test ;;
    "" | -*) fail "usage: install-oras.sh <version> <dir> | --self-test" ;;
    *)
        [ $# -eq 2 ] || fail "usage: install-oras.sh <version> <dir>"
        install_oras "$1" "$2"
        ;;
esac
