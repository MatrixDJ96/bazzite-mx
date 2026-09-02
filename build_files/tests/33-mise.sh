#!/usr/bin/env bash
# Smoke test of 33-mise.sh: mise from the vendored COPR with the pinned key,
# its activation in a login bash, and the skel config parsed as TOML with the
# four runtimes.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

KEY=/etc/pki/rpm-gpg/RPM-GPG-KEY-copr-jdxcode-mise
MISE_REPO=/etc/yum.repos.d/mise.repo
SKEL_CONFIG=/etc/skel/.config/mise/config.toml

check_copr_key() {
    check_key_fingerprint "$KEY"
    check_repo_reads_key "$MISE_REPO" "$KEY"

    check_rpm_key c83e991c "mise COPR"
}

# A throw-away HOME: mise and bash write state under it.
check_activation() {
    local home mise_type

    home=$(mktemp -d)

    mise_type=$(HOME=$home bash -lc 'type -t mise' 2> /dev/null || true)

    if [ "$mise_type" = "function" ]; then
        echo "OK: a login bash activates mise (profile.d)"
    else
        mise_type=$(HOME=$home bash -lc 'type -t mise' 2>&1 | head -n1 || true)
        echo "FAIL: mise not activated in a login bash: ${mise_type:-empty}"
    fi

    if HOME=$home mise --version > /dev/null 2>&1; then
        echo "OK: mise --version $(HOME=$home mise --version 2> /dev/null | head -n1)"
    else
        echo "FAIL: mise --version:" \
            "$(HOME=$home mise --version 2>&1 | head -n1 | on_one_line 'no output')"
    fi

    rm -rf "$home"
}

check_skel_config() {
    local config
    local runtimes_present='
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    tools = tomllib.load(f)["tools"]
sys.exit(0 if {"node", "python", "java", "dotnet"} <= set(tools) else 1)
'

    if python3 -c "$runtimes_present" "$SKEL_CONFIG" 2> /dev/null; then
        echo "OK: skel mise config.toml parses with node, python, java, dotnet"
    else
        config=$(grep -v '^#' "$SKEL_CONFIG" 2>&1 | tr '\n' ' ' || true)
        echo "FAIL: skel mise config.toml: ${config:-no line beyond comments}"
    fi
}

check_copr_key
check_activation
check_skel_config
