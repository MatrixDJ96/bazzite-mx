#!/usr/bin/env bash
# Smoke test of 33-mise.sh: mise from the vendored COPR with the pinned key,
# its activation in a login bash, and the skel config parsed as TOML with the
# four runtimes.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

CTX=$(dirname "$(realpath "$0")")/../..
# shellcheck source=../lib/gpg.sh
source "$CTX/build_files/lib/gpg.sh"
# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

KEY=/etc/pki/rpm-gpg/RPM-GPG-KEY-copr-jdxcode-mise
MISE_REPO=/etc/yum.repos.d/mise.repo
SKEL_CONFIG=/etc/skel/.config/mise/config.toml

check_mise_package() {
    if rpm -q mise > /dev/null && [ -x /usr/bin/mise ]; then
        echo "OK: mise $(rpm -q --qf '%{VERSION}' mise)"
    else
        echo "FAIL: mise not installed"
    fi
}

# The shipped key is the pinned one, the .repo reads it from the file with
# gpgcheck on, and dnf5 imported it into the rpm keyring at install.
check_copr_key() {
    local pinned=${KEY_FPR[$KEY]}
    local actual gpg_lines

    actual=$(key_fingerprint "$KEY" || true)
    if [ "$actual" = "$pinned" ]; then
        echo "OK: $KEY fingerprint $pinned"
    else
        echo "FAIL: $KEY fingerprint $actual"
    fi

    if grep -q "^gpgkey=file://$KEY$" "$MISE_REPO" && grep -q '^gpgcheck=1$' "$MISE_REPO"; then
        echo "OK: mise.repo reads the vendored key with gpgcheck=1"
    else
        gpg_lines=$(grep -E '^gpg' "$MISE_REPO" | tr '\n' ' ')
        echo "FAIL: mise.repo: $gpg_lines"
    fi

    check_rpm_key c83e991c "mise COPR"
}

# A throw-away HOME: mise and bash write state under it.
check_activation() {
    local home mise_type

    home=$(mktemp -d)

    mise_type=$(HOME=$home bash -lc 'type -t mise' 2> /dev/null || true)
    if [ "$mise_type" = "function" ]; then
        echo "OK: interactive bash activates mise (profile.d)"
    else
        mise_type=$(HOME=$home bash -lc 'type -t mise' 2>&1 | head -n1)
        echo "FAIL: mise not activated in a login bash: $mise_type"
    fi

    if HOME=$home mise --version > /dev/null 2>&1; then
        echo "OK: mise --version $(HOME=$home mise --version 2> /dev/null | head -n1)"
    else
        echo "FAIL: mise --version: $(HOME=$home mise --version 2>&1 | head -n1)"
    fi

    rm -rf "$home"
}

check_skel_config() {
    local runtimes_present='
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    tools = tomllib.load(f)["tools"]
sys.exit(0 if {"node", "python", "java", "dotnet"} <= set(tools) else 1)
'

    if python3 -c "$runtimes_present" "$SKEL_CONFIG"; then
        echo "OK: skel mise config.toml parses with node, python, java, dotnet"
    else
        echo "FAIL: skel mise config.toml: $(grep -v '^#' "$SKEL_CONFIG" 2>&1 | tr '\n' ' ')"
    fi
}

check_mise_package
check_copr_key
check_activation
check_skel_config
