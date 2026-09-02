#!/usr/bin/env bash
# Smoke test of 30-ide.sh: VS Code from the vendored repo with the pinned
# key, the skel settings, the per-user setup unit, and the extensions hook
# exercised on a fixture with a stub `code` and a stub `nm-online`.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

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
    local gpg_lines

    check_key_fingerprint "$KEY"

    if grep -q "^gpgkey=file://$KEY$" "$VSCODE_REPO" 2> /dev/null \
        && grep -q '^gpgcheck=1$' "$VSCODE_REPO" 2> /dev/null; then
        echo "OK: vscode.repo reads the vendored key with gpgcheck=1"
    else
        gpg_lines=$(grep -E '^gpg' "$VSCODE_REPO" 2>&1 | tr '\n' ' ' || true)
        echo "FAIL: vscode.repo: ${gpg_lines:-no gpg line}"
    fi

    check_rpm_key be1229cf "Microsoft"
}

check_skel_settings() {
    local update_mode settings

    update_mode=$(jq -r '."update.mode"' "$SKEL_SETTINGS" 2> /dev/null || true)

    if [ "$update_mode" = "none" ]; then
        echo "OK: skel settings.json sets update.mode none"
    else
        settings=$(cat "$SKEL_SETTINGS" 2>&1 | tr '\n' ' ' || true)
        echo "FAIL: skel settings.json: ${settings:-empty}"
    fi
}

# --- the extensions hook on a fixture -----------------------------------------

# A home with one of the three extensions installed, and a stub `code` on
# PATH that records every install asked for with --disable-telemetry in
# $CODE_STUB_LOG, refuses one without the flag, and fails every one of them
# when CODE_STUB_FAIL is set; a stub `nm-online` records every wait in
# $NM_ONLINE_LOG and times out.
fixture_create() {
    local fixture

    fixture=$(mktemp -d)
    mkdir -p "$fixture/home/.vscode/extensions" "$fixture/bin"

    cat > "$fixture/bin/code" << 'STUB'
#!/usr/bin/env bash
if [ "$1" != "--disable-telemetry" ] || [ "$2" != "--install-extension" ]; then
    echo "stub code: refused, no --disable-telemetry before --install-extension: $*" >&2
    exit 2
fi

if [ -n "${CODE_STUB_FAIL:-}" ]; then
    exit 1
fi

echo "$3" >> "${CODE_STUB_LOG:?}"
STUB
    cat > "$fixture/bin/nm-online" << 'STUB'
#!/usr/bin/env bash
echo "nm-online $*" >> "${NM_ONLINE_LOG:?}"
exit 1
STUB
    chmod +x "$fixture/bin/code" "$fixture/bin/nm-online"

    fixture_write_extensions "$fixture" MS-VSCode-Remote.remote-ssh
    : > "$fixture/installs"
    : > "$fixture/waits"

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
        NM_ONLINE_LOG=$fixture/waits bash "$EXTENSIONS_HOOK" 2>&1
}

installs_recorded_in() {
    local fixture=$1

    on_one_line none < "$fixture/installs"
}

check_hook_first_run() {
    local fixture=$1
    local expected_installs="ms-azuretools.vscode-containers ms-vscode-remote.remote-containers "
    local output installs update_mode

    if ! output=$(run_hook "$fixture"); then
        echo "FAIL: hook on fixture: $(on_one_line 'no output' <<< "$output");" \
            "installs: $(installs_recorded_in "$fixture")"
        return 0
    fi

    installs=$(sort "$fixture/installs" | tr '\n' ' ' || true)
    update_mode=$(jq -r '."update.mode"' "$fixture/home/.config/Code/User/settings.json" \
        2> /dev/null || true)

    if [ "$installs" = "$expected_installs" ] && [ "$update_mode" = "none" ] \
        && [ "$(cat "$fixture/waits")" = "nm-online -q -t 60" ]; then
        echo "OK: hook seeds the settings and installs the two missing extensions"
    else
        echo "FAIL: hook on fixture: $(on_one_line 'no output' <<< "$output");" \
            "installs: $(installs_recorded_in "$fixture");" \
            "waits: $(on_one_line none < "$fixture/waits")"
    fi

    # Known-bad: the line said `3 present`, the size of the list, while the
    # stub code records nothing: one was present before, one is present now.
    if grep -q '^bazzite-mx-vscode: 2 extension(s) installed, 1 present$' <<< "$output"; then
        echo "OK: hook counts the extensions VS Code records, not the list"
    else
        echo "FAIL: hook count line:" \
            "$(grep 'extension(s)' <<< "$output" | on_one_line 'no count line')"
    fi
}

# The settings the user wrote since the first run stay theirs.
check_hook_with_every_extension() {
    local fixture=$1
    local settings=$fixture/home/.config/Code/User/settings.json
    local output

    fixture_write_extensions "$fixture" ms-vscode-remote.remote-ssh \
        ms-vscode-remote.remote-containers ms-azuretools.vscode-containers
    : > "$fixture/installs"
    : > "$fixture/waits"
    echo '{"user": true}' > "$settings"

    if output=$(run_hook "$fixture") && [ ! -s "$fixture/installs" ] \
        && [ ! -s "$fixture/waits" ]; then
        echo "OK: hook installs nothing when every extension is present"
    else
        echo "FAIL: second hook run: $(on_one_line 'no output' <<< "$output");" \
            "installs: $(installs_recorded_in "$fixture");" \
            "waits: $(on_one_line none < "$fixture/waits")"
    fi

    if jq -e .user "$settings" > /dev/null 2>&1; then
        echo "OK: hook leaves the user's settings.json alone"
    else
        echo "FAIL: hook replaced the user's settings.json:" \
            "$(on_one_line 'empty' < "$settings")"
    fi
}

check_hook_with_failing_installs() {
    local fixture=$1
    local ids="ms-azuretools.vscode-containers ms-vscode-remote.remote-containers"
    local output

    ids+=" ms-vscode-remote.remote-ssh"
    rm -f "$fixture/home/.vscode/extensions/extensions.json"

    if output=$(CODE_STUB_FAIL=1 run_hook "$fixture"); then
        echo "FAIL: hook exited 0 with every install failing"
    elif grep -qF "ERROR: could not install $ids;" <<< "$output"; then
        echo "OK: hook reports and fails when an install fails"
    else
        echo "FAIL: hook failed without naming the extensions:" \
            "$(on_one_line 'no output' <<< "$output")"
    fi
}

# Known-bad: ~/.config is a regular file, so the seed cannot create its
# directory; the hook must say so on stderr and exit 1 rather than die on
# `set -e` in silence (docs/conventions.md § Boot hooks).
check_hook_with_config_as_file() {
    local fixture=$1
    local output

    rm -rf "$fixture/home/.config"
    : > "$fixture/home/.config"

    if output=$(run_hook "$fixture"); then
        echo "FAIL: hook exited 0 with ~/.config a file"
    elif grep -q '^bazzite-mx-vscode: ERROR: cannot seed' <<< "$output"; then
        echo "OK: hook names the seed it cannot write and fails"
    else
        echo "FAIL: hook failed without naming the seed: $(on_one_line 'no output' <<< "$output")"
    fi

    rm -f "$fixture/home/.config"
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
check_hook_with_config_as_file "$fixture"
rm -rf "$fixture"
