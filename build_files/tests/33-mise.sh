#!/usr/bin/env bash
# mise from the vendored COPR with the pinned key, its activation in a login
# bash, and the skel config parsed as TOML with the four runtimes.
set -euo pipefail

CTX=$(dirname "$(realpath "$0")")/../..
# shellcheck source=../lib/gpg.sh
source "$CTX/build_files/lib/gpg.sh"

if rpm -q mise > /dev/null && [ -x /usr/bin/mise ]; then
    echo "OK: mise $(rpm -q --qf '%{VERSION}' mise)"
else
    echo "FAIL: mise not installed"
fi

KEY=/etc/pki/rpm-gpg/RPM-GPG-KEY-copr-jdxcode-mise
FPR=${KEY_FPR[$KEY]}
if [ "$(key_fingerprint "$KEY")" = "$FPR" ]; then
    echo "OK: $KEY fingerprint $FPR"
else
    echo "FAIL: $KEY fingerprint $(key_fingerprint "$KEY" || true)"
fi
if grep -q "^gpgkey=file://$KEY$" /etc/yum.repos.d/mise.repo && grep -q '^gpgcheck=1$' /etc/yum.repos.d/mise.repo; then
    echo "OK: mise.repo reads the vendored key with gpgcheck=1"
else
    echo "FAIL: mise.repo: $(grep -E '^gpg' /etc/yum.repos.d/mise.repo | tr '\n' ' ')"
fi
if rpm -q gpg-pubkey --qf '%{VERSION}\n' | grep -qi 'c83e991c$'; then
    echo "OK: mise COPR key in the rpm keyring"
else
    echo "FAIL: mise COPR key (…c83e991c) not in the rpm keyring"
fi

# A throw-away HOME: mise and bash write state under it.
home=$(mktemp -d)
if [ "$(HOME=$home bash -lc 'type -t mise' 2> /dev/null)" = "function" ]; then
    echo "OK: interactive bash activates mise (profile.d)"
else
    echo "FAIL: mise not activated in a login bash: $(HOME=$home bash -lc 'type -t mise' 2>&1 | head -n1)"
fi
if HOME=$home mise --version > /dev/null 2>&1; then
    echo "OK: mise --version $(HOME=$home mise --version 2> /dev/null | head -n1)"
else
    echo "FAIL: mise --version: $(HOME=$home mise --version 2>&1 | head -n1)"
fi
rm -rf "$home"

SKEL=/etc/skel/.config/mise/config.toml
if python3 - "$SKEL" << 'PY'; then
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    tools = tomllib.load(f)["tools"]
sys.exit(0 if {"node", "python", "java", "dotnet"} <= set(tools) else 1)
PY
    echo "OK: skel mise config.toml parses with node, python, java, dotnet"
else
    echo "FAIL: skel mise config.toml: $(cat "$SKEL" 2>&1 | grep -v '^#' | tr '\n' ' ')"
fi
