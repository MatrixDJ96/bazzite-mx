#!/usr/bin/env bash
# Installs the ORAS CLI from its own GitHub release: the tarball and the
# release's checksums file are downloaded, the tarball is refused unless its
# sha256 is the one the checksums file lists, and the oras binary is extracted
# into <dir>. It stands in for the setup-oras action, which knows only the
# versions embedded in its own release: docs/gotchas.md § `setup-oras` installs
# only the ORAS versions embedded in its own release.
#
# Usage: install-oras.sh <version> <dir>
#          <version>  the ORAS release, X.Y.Z without the leading v
#          <dir>      where the oras binary lands, created when missing
#        install-oras.sh --self-test
# Environment: FIXTURE_DIR, a directory holding the two release files, stands
#   in for the download; the self-test uses it.
# Output: `checksum ok: <tarball>`, then `install-oras ok: <oras version> in
#   <dir>`, on stdout.
# Exit status: 0 installed; 1 when the version is not X.Y.Z, the checksums
#   file has no line for the tarball, the sha256 differs or the tarball holds
#   no oras binary, the reason on stderr as `install-oras: …`; curl's or tar's
#   own status when a download or the extraction fails.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

RELEASES=https://github.com/oras-project/oras/releases/download

# --- the release files --------------------------------------------------------

# tarball_name <version>: the linux amd64 tarball's file name in the release.
tarball_name() {
    local version=$1

    echo "oras_${version}_linux_amd64.tar.gz"
}

# checksums_name <version>: the release's checksums file name.
checksums_name() {
    local version=$1

    echo "oras_${version}_checksums.txt"
}

# fetch_release_files <version> <work dir>: the tarball and the checksums file
# into the work dir, copied from FIXTURE_DIR when it is set.
fetch_release_files() {
    local version=$1
    local work=$2
    local file

    for file in "$(tarball_name "$version")" "$(checksums_name "$version")"; do
        if [ -n "${FIXTURE_DIR:-}" ]; then
            cp "$FIXTURE_DIR/$file" "$work/$file"
        else
            curl -fsSL --proto '=https' --retry 3 -o "$work/$file" "$RELEASES/v${version}/$file"
        fi
    done
}

# verify_tarball <version> <work dir>: status 0 with `checksum ok: <tarball>`
# when the tarball's sha256 is the one the checksums file lists for it; status
# 1 with the reason when the file has no line for the tarball or the sum
# differs.
verify_tarball() {
    local version=$1
    local work=$2
    local tarball checksum_line expected_sum actual_sum

    tarball=$(tarball_name "$version")
    checksum_line=$(grep " ${tarball}\$" "$work/$(checksums_name "$version")" || true)

    if [ -z "$checksum_line" ]; then
        print_error "no checksum line for $tarball"
        return 1
    fi

    expected_sum=${checksum_line%% *}
    actual_sum=$(sha256sum "$work/$tarball" | cut -d' ' -f1)
    if [ "$actual_sum" != "$expected_sum" ]; then
        print_error "checksum mismatch for $tarball"
        return 1
    fi

    echo "checksum ok: $tarball"
}

# --- the install --------------------------------------------------------------

# install_oras <version> <dir>: download, verify and extract the oras binary
# into <dir>; exits 1 with the reason when the version, the checksum or the
# tarball is refused.
install_oras() {
    local version=$1
    local dir=$2
    local work

    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        exit_with_error "version '$version' is not X.Y.Z"
    fi

    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    fetch_release_files "$version" "$work"

    if ! verify_tarball "$version" "$work"; then
        exit 1
    fi

    mkdir -p "$dir"
    tar -xzf "$work/$(tarball_name "$version")" -C "$dir" oras
    if [ ! -x "$dir/oras" ]; then
        exit_with_error "no oras binary in the tarball"
    fi

    echo "install-oras ok: $("$dir/oras" version | head -n1) in $dir"
}

# --- self-test ----------------------------------------------------------------

SELF_TEST_VERSION=9.9.9

# self_test_write_release <fixture dir>: a stand-in tarball and the checksums
# file with the line that matches it.
self_test_write_release() {
    local fixture=$1
    local tarball checksum

    tarball=$(tarball_name "$SELF_TEST_VERSION")
    printf 'oras' > "$fixture/$tarball"

    checksum=$(sha256sum "$fixture/$tarball" | cut -d' ' -f1)
    printf '%s  %s\n' "$checksum" "$tarball" > "$fixture/$(checksums_name "$SELF_TEST_VERSION")"
}

# self_test_verify <dir>: the matching tarball accepted; a tampered tarball and
# a checksums file without the tarball's line refused.
self_test_verify() {
    local dir=$1
    local fixture=$dir/fixture
    local work=$dir/work

    mkdir -p "$fixture" "$work"
    self_test_write_release "$fixture"
    FIXTURE_DIR=$fixture fetch_release_files "$SELF_TEST_VERSION" "$work"

    if ! verify_tarball "$SELF_TEST_VERSION" "$work" > /dev/null; then
        fail_self_test "a matching checksum refused"
    fi

    printf 'tampered' > "$work/$(tarball_name "$SELF_TEST_VERSION")"
    REFUSED=$((REFUSED + 1))
    if verify_tarball "$SELF_TEST_VERSION" "$work" > /dev/null 2>&1; then
        fail_self_test "a mismatching checksum accepted"
    fi

    sed -i 's/linux_amd64/linux_arm64/' "$work/$(checksums_name "$SELF_TEST_VERSION")"
    REFUSED=$((REFUSED + 1))
    if verify_tarball "$SELF_TEST_VERSION" "$work" > /dev/null 2>&1; then
        fail_self_test "a missing checksum line accepted"
    fi
}

self_test() {
    local dir

    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN

    self_test_verify "$dir"

    echo "self-test ok: 1 matching checksum accepted, $REFUSED bad inputs refused"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    "" | -*)
        exit_with_error "usage: install-oras.sh <version> <dir> | --self-test"
        ;;
    *)
        if [ $# -ne 2 ]; then
            exit_with_error "usage: install-oras.sh <version> <dir>"
        fi
        install_oras "$1" "$2"
        ;;
esac
