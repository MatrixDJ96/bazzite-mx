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
# Exit status: 0 installed; 1 on every refusal, the reason on stderr as
#   `install-oras: …`: a download failed, the checksums file has no line for
#   the tarball, the sha256 differs, or the tarball is not a tarball or holds
#   no oras binary.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

RELEASES=https://github.com/oras-project/oras/releases/download

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# --- the release files --------------------------------------------------------

tarball_name() {
    local version=$1

    echo "oras_${version}_linux_amd64.tar.gz"
}

checksums_name() {
    local version=$1

    echo "oras_${version}_checksums.txt"
}

# fetch_release_files <version> <work dir>: the tarball and the checksums file
# into the work dir, copied from FIXTURE_DIR when it is set.
fetch_release_files() {
    local version=$1
    local work=$2
    local file error

    for file in "$(tarball_name "$version")" "$(checksums_name "$version")"; do
        if [ -n "${FIXTURE_DIR:-}" ]; then
            cp "$FIXTURE_DIR/$file" "$work/$file"
        else
            if ! error=$(curl -fsSL --proto '=https' --retry 3 -o "$work/$file" \
                "$RELEASES/v${version}/$file" 2>&1); then
                error=${error//$'\n'/ }
                exit_with_error "cannot fetch $RELEASES/v${version}/$file:" \
                    "${error:-no output from curl}"
            fi
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
    actual_sum=$(sha256sum "$work/$tarball")
    actual_sum=${actual_sum%% *}

    if [ "$actual_sum" != "$expected_sum" ]; then
        print_error "checksum mismatch for $tarball"
        return 1
    fi

    echo "checksum ok: $tarball"
}

# --- the install --------------------------------------------------------------

# install_oras <version> <dir>: download, verify and extract the oras binary
# into <dir>; exits 1 with the reason when a download fails or the checksum
# or the tarball is refused.
install_oras() {
    local version=$1
    local dir=$2
    local installed

    fetch_release_files "$version" "$WORK_DIR"

    if ! verify_tarball "$version" "$WORK_DIR"; then
        exit 1
    fi

    mkdir -p "$dir"

    if ! tar -xzf "$WORK_DIR/$(tarball_name "$version")" -C "$dir" oras 2> /dev/null \
        || [ ! -x "$dir/oras" ]; then
        exit_with_error "no oras binary in the tarball"
    fi

    # `oras version` opens with `Version:<padding><X.Y.Z>`; the rest is Go,
    # OS and commit lines the log does not need.
    installed=$("$dir/oras" version)
    installed=${installed%%$'\n'*}
    installed=${installed##* }

    echo "install-oras ok: $installed in $dir"
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

    checksum=$(sha256sum "$fixture/$tarball")
    checksum=${checksum%% *}
    printf '%s  %s\n' "$checksum" "$tarball" > "$fixture/$(checksums_name "$SELF_TEST_VERSION")"
}

# self_test_verify <dir>: the matching tarball accepted; a tampered tarball and
# a checksums file without the tarball's line refused.
self_test_verify() {
    local dir=$1
    local fixture=$dir/fixture
    local work=$dir/work
    local output

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

    if output=$(verify_tarball "$SELF_TEST_VERSION" "$work" 2>&1); then
        fail_self_test "a missing checksum line accepted"
    fi

    if ! grep -q '^install-oras: no checksum line for ' <<< "$output"; then
        fail_self_test "a missing checksum line refused for another reason: $output"
    fi
}

# self_test_write_tarball_release <fixture dir> <member>: a real gzip tarball
# holding one executable named <member>, and its checksums line.
self_test_write_tarball_release() {
    local fixture=$1
    local member=$2
    local tarball checksum

    tarball=$(tarball_name "$SELF_TEST_VERSION")
    rm -rf "$fixture"
    mkdir -p "$fixture/tree"
    printf '#!/usr/bin/env bash\necho "Version: %s"\n' "$SELF_TEST_VERSION" \
        > "$fixture/tree/$member"
    chmod 755 "$fixture/tree/$member"
    tar -czf "$fixture/$tarball" -C "$fixture/tree" "$member"

    checksum=$(sha256sum "$fixture/$tarball")
    checksum=${checksum%% *}
    printf '%s  %s\n' "$checksum" "$tarball" > "$fixture/$(checksums_name "$SELF_TEST_VERSION")"
}

# self_test_install <dir>: the binary installed from a tarball that holds it;
# a tarball without it refused with the script's own line (known-bad: tar's
# own lines and status 2).
self_test_install() {
    local dir=$1
    local fixture=$dir/release
    local output

    self_test_write_tarball_release "$fixture" oras

    if ! output=$(FIXTURE_DIR=$fixture install_oras "$SELF_TEST_VERSION" "$dir/bin" 2>&1) \
        || ! grep -q "^install-oras ok: $SELF_TEST_VERSION in " <<< "$output"; then
        fail_self_test "a tarball holding oras refused: $(tail -n1 <<< "$output")"
    fi

    self_test_write_tarball_release "$fixture" notoras
    REFUSED=$((REFUSED + 1))

    if output=$(FIXTURE_DIR=$fixture install_oras "$SELF_TEST_VERSION" "$dir/bin2" 2>&1); then
        fail_self_test "a tarball without oras accepted"
    fi

    if ! grep -q '^install-oras: no oras binary in the tarball$' <<< "$output" \
        || grep -q '^tar:' <<< "$output"; then
        fail_self_test "a tarball without oras: tar's line or no refusal: $(head -n1 <<< "$output")"
    fi
}

# self_test_fetch_failure <dir>: a curl that failed on every retry leaves one
# `install-oras:` line carrying its reason, never one line per try.
self_test_fetch_failure() {
    local dir=$1
    local output

    mkdir -p "$dir/stubs" "$dir/fetch"
    printf '%s\n' '#!/usr/bin/env bash' \
        'echo "curl: (22) The requested URL returned error: 503" >&2' \
        'echo "curl: (22) The requested URL returned error: 503" >&2' 'exit 22' \
        > "$dir/stubs/curl"
    chmod +x "$dir/stubs/curl"
    REFUSED=$((REFUSED + 1))

    if output=$(PATH=$dir/stubs:$PATH \
        fetch_release_files "$SELF_TEST_VERSION" "$dir/fetch" 2>&1); then
        fail_self_test "a failed download accepted"
    fi

    if [ "$(grep -c '' <<< "$output")" -ne 1 ] \
        || ! grep -q '^install-oras: cannot fetch .*: curl: (22) ' <<< "$output"; then
        fail_self_test "a failed download not folded into one line: ${output//$'\n'/ }"
    fi
}

self_test() {
    local dir

    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN

    self_test_verify "$dir"
    self_test_install "$dir"
    self_test_fetch_failure "$dir"

    echo "self-test ok: 1 matching checksum accepted, 1 binary installed," \
        "$REFUSED bad inputs refused"
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
