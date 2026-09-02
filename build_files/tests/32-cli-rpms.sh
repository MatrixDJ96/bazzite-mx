#!/usr/bin/env bash
# Smoke test of 32-cli-rpms.sh: every package of the list, the two whose
# version this repo's tooling depends on (shfmt, ShellCheck), and the
# binaries on PATH.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

check_packages() {
    check_pkg ShellCheck android-tools bcc bcc-tools bpftop bpftrace ccache flatpak-builder \
        gh glab iotop-c nicstat numactl ripgrep shfmt sysprof trace-cmd
}

# Fedora's shfmt prints an empty --version, so the rpm version is the
# reference and a round trip proves the binary runs.
check_shfmt() {
    local version

    version=$(rpm -q --qf '%{VERSION}' shfmt)
    if [[ "$version" == 3.7.* ]] && [ "$(echo 'x=1' | shfmt)" = "x=1" ]; then
        echo "OK: shfmt $version, formats"
    else
        echo "FAIL: shfmt $version, not 3.7.x, or it does not run"
    fi
}

check_shellcheck() {
    local reported

    reported=$(shellcheck --version 2>&1 || true)

    if grep -q '^version: 0\.1[1-9]' <<< "$reported"; then
        echo "OK: shellcheck $(sed -n 's/^version: //p' <<< "$reported")"
    else
        echo "FAIL: shellcheck version: $(head -n2 <<< "$reported" | tr '\n' ' ')"
    fi
}

# iotop-c installs its binary under the name iotop.
check_binaries_on_path() {
    local binary

    for binary in gh glab rg iotop bpftrace; do
        if command -v "$binary" > /dev/null; then
            echo "OK: $binary on PATH"
        else
            echo "FAIL: $binary not on PATH"
        fi
    done
}

check_packages
check_shfmt
check_shellcheck
check_binaries_on_path
