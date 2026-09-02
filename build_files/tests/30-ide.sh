#!/usr/bin/env bash
# Smoke test of 30-ide.sh: VS Code from the vendored repo with the pinned
# key, the skel settings, the per-user setup unit, and the extensions hook
# exercised on a fixture with a stub `code`.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
# shellcheck source=../lib/gpg.sh
source "$CTX/build_files/lib/gpg.sh"

KEY=/etc/pki/rpm-gpg/RPM-GPG-KEY-microsoft
VSCODE_REPO=/etc/yum.repos.d/vscode.repo
SKEL_SETTINGS=/etc/skel/.config/Code/User/settings.json
EXTENSIONS_HOOK=/usr/share/ublue-os/user-setup.hooks.d/11-bazzite-mx-vscode-extensions.sh

# --- the image ----------------------------------------------------------------

check_code_package() {
    if rpm -q code > /dev/null && [ -x /usr/bin/code ]; then
        echo "OK: code $(rpm -q --qf '%{VERSION}' code)"
    else
        echo "FAIL: code not installed"
    fi
}

# The shipped key is the pinned one, the .repo reads it from the file with
# gpgcheck on, and dnf5 imported it into the rpm keyring at install.
check_microsoft_key() {
    local pinned=${KEY_FPR[$KEY]}
    local actual gpg_lines

    actual=$(key_fingerprint "$KEY" || true)
    if [ "$actual" = "$pinned" ]; then
        echo "OK: $KEY fingerprint $pinned"
    else
        echo "FAIL: $KEY fingerprint $actual"
    fi

    if grep -q "^gpgkey=file://$KEY$" "$VSCODE_REPO" && grep -q '^gpgcheck=1$' "$VSCODE_REPO"; then
        echo "OK: vscode.repo reads the vendored key with gpgcheck=1"
    else
        gpg_lines=$(grep -E '^gpg' "$VSCODE_REPO" | tr '\n' ' ')
        echo "FAIL: vscode.repo: $gpg_lines"
    fi

    check_rpm_key be1229cf "Microsoft"
}

check_skel_settings() {
    local update_mode

    update_mode=$(jq -r '."update.mode"' "$SKEL_SETTINGS" 2> /dev/null || true)
    if [ "$update_mode" = "none" ]; then
        echo "OK: skel settings.json sets update.mode none"
    else
        echo "FAIL: skel settings.json: $(cat "$SKEL_SETTINGS" 2>&1 | tr '\n' ' ')"
    fi
}

# --- the extensions hook on a fixture -----------------------------------------

# A home with one of the three extensions installed, and a stub `code` on
# PATH that records every install it is asked for in $CODE_STUB_LOG and
# fails every one of them when CODE_STUB_FAIL is set.
fixture_create() {
    local fixture

    fixture=$(mktemp -d)
    mkdir -p "$fixture/home/.vscode/extensions" "$fixture/bin"

    cat > "$fixture/bin/code" << 'STUB'
#!/usr/bin/env bash
if [ "$1" != "--install-extension" ]; then
    exit 2
fi

if [ -n "${CODE_STUB_FAIL:-}" ]; then
    exit 1
fi

echo "$2" >> "${CODE_STUB_LOG:?}"
STUB
    chmod +x "$fixture/bin/code"

    fixture_write_extensions "$fixture" MS-VSCode-Remote.remote-ssh
    : > "$fixture/installs"

    echo "$fixture"
}

# fixture_write_extensions <fixture> <id>...: the extensions.json VS Code
# keeps, listing the given extensions as installed.
fixture_write_extensions() {
    local fixture=$1
    shift

    printf '%s\n' "$@" \
        | jq -R '{identifier: {id: .}}' \
        | jq -s . > "$fixture/home/.vscode/extensions/extensions.json"
}

run_hook() {
    local fixture=$1

    HOME=$fixture/home PATH=$fixture/bin:$PATH CODE_STUB_LOG=$fixture/installs \
        bash "$EXTENSIONS_HOOK" 2>&1
}

installs_recorded_in() {
    local fixture=$1

    tr '\n' ' ' < "$fixture/installs"
}

check_hook_first_run() {
    local fixture=$1
    local expected_installs="ms-azuretools.vscode-containers ms-vscode-remote.remote-containers "
    local output installs update_mode

    if ! output=$(run_hook "$fixture"); then
        echo "FAIL: hook on fixture: $output; installs: $(installs_recorded_in "$fixture")"
        return 0
    fi

    installs=$(sort "$fixture/installs" | tr '\n' ' ')
    update_mode=$(jq -r '."update.mode"' "$fixture/home/.config/Code/User/settings.json" \
        2> /dev/null || true)

    if [ "$installs" = "$expected_installs" ] && [ "$update_mode" = "none" ]; then
        echo "OK: hook seeds the settings and installs the two missing extensions"
    else
        echo "FAIL: hook on fixture: $output; installs: $(installs_recorded_in "$fixture")"
    fi
}

check_hook_with_every_extension() {
    local fixture=$1
    local output

    fixture_write_extensions "$fixture" ms-vscode-remote.remote-ssh \
        ms-vscode-remote.remote-containers ms-azuretools.vscode-containers
    : > "$fixture/installs"

    if output=$(run_hook "$fixture") && [ ! -s "$fixture/installs" ]; then
        echo "OK: hook installs nothing when every extension is present"
    else
        echo "FAIL: second hook run: $output; installs: $(installs_recorded_in "$fixture")"
    fi
}

check_hook_with_failing_installs() {
    local fixture=$1
    local output

    rm -f "$fixture/home/.vscode/extensions/extensions.json"

    if output=$(CODE_STUB_FAIL=1 run_hook "$fixture"); then
        echo "FAIL: hook exited 0 with every install failing"
    elif grep -q 'ERROR: could not install' <<< "$output"; then
        echo "OK: hook reports and fails when an install fails"
    else
        echo "FAIL: hook failed without naming the extensions: $output"
    fi
}

# --- main ---------------------------------------------------------------------

check_code_package
check_microsoft_key
check_skel_settings
check_unit_state --global ublue-user-setup.service enabled

fixture=$(fixture_create)
check_hook_first_run "$fixture"
check_hook_with_every_extension "$fixture"
check_hook_with_failing_installs "$fixture"
rm -rf "$fixture"
