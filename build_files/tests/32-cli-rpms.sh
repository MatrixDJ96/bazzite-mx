#!/usr/bin/env bash
# Every package of the list, plus the two whose version this repo's tooling
# depends on.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

check_pkg ShellCheck android-tools bcc bcc-tools bpftop bpftrace ccache flatpak-builder gh glab \
    iotop-c nicstat numactl ripgrep shfmt sysprof trace-cmd

# Fedora's shfmt prints an empty --version, so the rpm version is the
# reference and a round trip proves the binary runs.
v=$(rpm -q --qf '%{VERSION}' shfmt)
if [[ "$v" == 3.7.* ]] && [ "$(echo 'x=1' | shfmt)" = "x=1" ]; then
    echo "OK: shfmt $v, formats"
else
    echo "FAIL: shfmt $v, not 3.7.x, or it does not run"
fi
if shellcheck --version 2> /dev/null | grep -q '^version: 0\.1[1-9]'; then
    echo "OK: shellcheck $(shellcheck --version | sed -n 's/^version: //p')"
else
    echo "FAIL: shellcheck version: $(shellcheck --version 2>&1 | head -n2 | tr '\n' ' ')"
fi
# iotop-c installs its binary under the name iotop.
for bin in gh glab rg iotop bpftrace; do
    if command -v "$bin" > /dev/null; then
        echo "OK: $bin on PATH"
    else
        echo "FAIL: $bin not on PATH"
    fi
done
