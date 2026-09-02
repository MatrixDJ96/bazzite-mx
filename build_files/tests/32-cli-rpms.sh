#!/usr/bin/env bash
# Smoke test of 32-cli-rpms.sh: every package of the list, the two this
# repo's tooling runs (shfmt, ShellCheck) proven to run, and the binaries on
# PATH.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

check_packages() {
    check_pkg ShellCheck android-tools bcc bcc-tools bpftop bpftrace ccache flatpak-builder \
        gh glab iotop-c nicstat numactl ripgrep shfmt sysprof telnet trace-cmd
}

# Fedora's shfmt prints an empty --version, so the OK line takes the rpm
# version and a round trip proves the binary runs.
check_shfmt() {
    local version

    version=$(rpm -q --qf '%{VERSION}' shfmt 2>&1 || true)

    if [ "$(echo 'x=1' | shfmt 2> /dev/null)" = "x=1" ]; then
        echo "OK: shfmt $version, formats"
    else
        echo "FAIL: shfmt '${version:-empty}' does not run"
    fi
}

check_shellcheck() {
    local reported

    if reported=$(shellcheck --version 2>&1); then
        echo "OK: shellcheck $(sed -n 's/^version: //p' <<< "$reported")"
    else
        echo "FAIL: shellcheck --version: $(head -n2 <<< "$reported" | on_one_line 'no output')"
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
