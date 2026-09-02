#!/usr/bin/env bash
# VS Code from the vendored repo with the pinned key, the skel settings, the
# user unit, and the extensions hook on a fixture with a stub `code`.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
# shellcheck source=../lib/gpg.sh
source "$CTX/build_files/lib/gpg.sh"

if rpm -q code > /dev/null && [ -x /usr/bin/code ]; then
    echo "OK: code $(rpm -q --qf '%{VERSION}' code)"
else
    echo "FAIL: code not installed"
fi

KEY=/etc/pki/rpm-gpg/RPM-GPG-KEY-microsoft
FPR=${KEY_FPR[$KEY]}
if [ "$(key_fingerprint "$KEY")" = "$FPR" ]; then
    echo "OK: $KEY fingerprint $FPR"
else
    echo "FAIL: $KEY fingerprint $(key_fingerprint "$KEY" || true)"
fi
if grep -q "^gpgkey=file://$KEY$" /etc/yum.repos.d/vscode.repo && grep -q '^gpgcheck=1$' /etc/yum.repos.d/vscode.repo; then
    echo "OK: vscode.repo reads the vendored key with gpgcheck=1"
else
    echo "FAIL: vscode.repo: $(grep -E '^gpg' /etc/yum.repos.d/vscode.repo | tr '\n' ' ')"
fi
if rpm -q gpg-pubkey --qf '%{VERSION}\n' | grep -qi 'be1229cf$'; then
    echo "OK: Microsoft key in the rpm keyring"
else
    echo "FAIL: Microsoft key (…be1229cf) not in the rpm keyring"
fi

SKEL=/etc/skel/.config/Code/User/settings.json
if [ "$(jq -r '."update.mode"' "$SKEL" 2> /dev/null)" = "none" ]; then
    echo "OK: skel settings.json sets update.mode none"
else
    echo "FAIL: skel settings.json: $(cat "$SKEL" 2>&1 | tr '\n' ' ')"
fi

check_unit_state --global ublue-user-setup.service enabled

# The stub `code` records every install it is asked for; the fixture's
# extensions.json lists one of the three extensions.
HOOK=/usr/share/ublue-os/user-setup.hooks.d/11-bazzite-mx-vscode-extensions.sh
fx=$(mktemp -d)
mkdir -p "$fx/home/.vscode/extensions" "$fx/bin"
cat > "$fx/bin/code" << 'STUB'
#!/usr/bin/env bash
[ "$1" = "--install-extension" ] || exit 2
[ -z "${CODE_STUB_FAIL:-}" ] || exit 1
echo "$2" >> "${CODE_STUB_LOG:?}"
STUB
chmod +x "$fx/bin/code"
echo '[{"identifier":{"id":"MS-VSCode-Remote.remote-ssh"},"version":"0.100.0"}]' > "$fx/home/.vscode/extensions/extensions.json"
: > "$fx/installs"
run_hook() { HOME=$fx/home PATH=$fx/bin:$PATH CODE_STUB_LOG=$fx/installs bash "$HOOK" 2>&1; }
if out=$(run_hook) \
    && [ "$(sort "$fx/installs" | tr '\n' ' ')" = "ms-azuretools.vscode-containers ms-vscode-remote.remote-containers " ] \
    && [ "$(jq -r '."update.mode"' "$fx/home/.config/Code/User/settings.json")" = "none" ]; then
    echo "OK: hook seeds the settings and installs the two missing extensions"
else
    echo "FAIL: hook on fixture: $out; installs: $(tr '\n' ' ' < "$fx/installs")"
fi
echo '[{"identifier":{"id":"ms-vscode-remote.remote-ssh"}},{"identifier":{"id":"ms-vscode-remote.remote-containers"}},{"identifier":{"id":"ms-azuretools.vscode-containers"}}]' > "$fx/home/.vscode/extensions/extensions.json"
: > "$fx/installs"
if out=$(run_hook) && [ ! -s "$fx/installs" ]; then
    echo "OK: hook installs nothing when every extension is present"
else
    echo "FAIL: second hook run: $out; installs: $(tr '\n' ' ' < "$fx/installs")"
fi
rm -f "$fx/home/.vscode/extensions/extensions.json"
if out=$(CODE_STUB_FAIL=1 run_hook); then
    echo "FAIL: hook exited 0 with every install failing"
elif grep -q 'ERROR: could not install' <<< "$out"; then
    echo "OK: hook reports and fails when an install fails"
else
    echo "FAIL: hook failed without naming the extensions: $out"
fi
rm -rf "$fx"
