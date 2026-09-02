#!/usr/bin/env bash
# Smoke test of 70-justfile.sh: our recipe file imported once, every recipe
# reachable exactly once, and the self-test of 70-justfile.sh run; then the
# recipes that print more after their call print it only when the call
# succeeded, run as nobody against stubs. The helpers' own cases live in
# their tests and self-tests (docs/conventions.md § Positive control), their
# files are proven in place by tests/01-system-files.sh; what needs a booted
# host is proven there.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines. The test
# itself stops when setup-sunshine enable leaves no ~/.config/sunshine.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
JUST_DIR=/usr/share/ublue-os/just
MASTER=/usr/share/ublue-os/justfile
OURS=$JUST_DIR/95-bazzite-mx.just
SNAPSHOT=$BUILD_STATE/just.base.summary
OUR_RECIPES="setup-msi setup-panels"
REPLACING_RECIPES="setup-sunshine setup-virtualization"

# --- the recipe files ---------------------------------------------------------

check_our_recipe_file() {
    local defined

    defined=$(recipe_set "$OURS" | tr '\n' ' ' || true)

    if [ "$defined" = "$OUR_RECIPES " ]; then
        echo "OK: $OURS defines exactly: $OUR_RECIPES"
    else
        echo "FAIL: $OURS defines: ${defined:-nothing (the file does not parse)}"
    fi
}

check_master_justfile() {
    local import_count master_set recipe missing="" duplicates

    import_count=$(grep -c "^import \"$OURS\"$" "$MASTER" 2> /dev/null || true)

    if [ "$import_count" -eq 1 ]; then
        echo "OK: $MASTER imports $OURS once"
    else
        echo "FAIL: $MASTER imports $OURS ${import_count} times"
    fi

    master_set=$(recipe_set "$MASTER" || true)

    for recipe in $OUR_RECIPES; do
        if ! grep -qx "$recipe" <<< "$master_set"; then
            missing="$missing $recipe"
        fi
    done

    if [ -z "$missing" ]; then
        echo "OK: ujust exposes every recipe of ours ($(wc -l <<< "$master_set") recipes in all)"
    else
        echo "FAIL: ujust does not expose:$missing"
    fi

    duplicates=$(recipe_set_of_every_file | sort | uniq -d || true)

    if [ -z "$duplicates" ]; then
        echo "OK: no recipe defined in two files"
    else
        echo "FAIL: recipes defined twice: $(on_one_line 'none' <<< "$duplicates")"
    fi
}

recipe_set_of_every_file() {
    local file

    for file in "$JUST_DIR"/*.just; do
        recipe_set "$file"
    done
}

# recorded_recipes_of <file name>: the recipes 00-prep.sh recorded for the
# base's file, one per line, sorted; empty when the snapshot has no row.
recorded_recipes_of() {
    local file=$1

    grep "^$file: " "$SNAPSHOT" 2> /dev/null \
        | sed 's/^[^:]*: //' \
        | tr ' ' '\n' \
        | sed '/^$/d' \
        | sort
}

# The two files that replace a base file hold the recipes the base's held.
check_replacing_files() {
    local file recorded

    for file in 84-bazzite-virt.just 82-bazzite-sunshine.just; do
        recorded=$(recorded_recipes_of "$file" || true)

        if [ -n "$recorded" ] && [ "$(recipe_set "$JUST_DIR/$file")" = "$recorded" ]; then
            echo "OK: $file holds what the base's held ($(tr '\n' ' ' <<< "$recorded"))"
        else
            echo "FAIL: $file: ours $(recipe_set "$JUST_DIR/$file" | on_one_line none)" \
                "vs base $(on_one_line none <<< "$recorded")"
        fi
    done
}

check_help() {
    local recipe

    for recipe in $OUR_RECIPES; do
        check_recipe_help "$MASTER" "$recipe"
    done
}

# --- a failed call is the recipe's status -------------------------------------
# setup-msi enable prints a
# `Done.` line after its call, setup-panels prints what plasmashell
# answered, setup-sunshine enable and disable report the service and its
# status reads the unit: the recipe runs as nobody (the recipes refuse root)
# with stubs of sudo, gdbus, systemctl and getcap first on PATH: under
# STUB_FAILS the first three refuse and getcap prints no capability, so the
# line and the status can be read in the build.
# Known-bad: the recipes printed `Done.` and exited 0 after a helper that had
# printed `ERROR:` and exited 1; setup-panels exited 0 after a failed gdbus
# call, the pipe into sed hiding its status; setup-sunshine reported the
# service enabled after a systemctl that had refused.

fixture_recipe_stubs() {
    local dir=$1

    mkdir -p "$dir/bin" "$dir/home"
    chmod 755 "$dir" "$dir/bin"
    chmod 777 "$dir/home"
    cat > "$dir/bin/sudo" << 'STUB'
#!/usr/bin/bash
if [ "${STUB_FAILS:-0}" = 1 ]; then
    echo "ERROR: stub refused $*"
    exit 1
fi

echo "stub ran $*"
STUB
    cat > "$dir/bin/gdbus" << 'STUB'
#!/usr/bin/bash
if [ "$1" = call ] && [ "${STUB_FAILS:-0}" = 1 ]; then
    echo "Error: stub refused gdbus $*" >&2
    exit 1
fi

if [ "$1" = call ]; then
    echo "('stub applied the panels',)"
fi
STUB
    cat > "$dir/bin/systemctl" << 'STUB'
#!/usr/bin/bash
# The system unit virtqemud.socket is enabled and active, the user's
# Sunshine unit is not; the words and statuses are systemctl's. Under
# STUB_FAILS is-active, and is-enabled of the user unit, answer nothing,
# status 4, as without a bus.
# The Sunshine unit loads from the RPM, from the home under
# STUB_FRAGMENT_IN_HOME.
case "$*" in
    "--user show -p FragmentPath --value "*)
        if [ "${STUB_FRAGMENT_IN_HOME:-0}" = 1 ]; then
            echo "$HOME/.config/systemd/user/$6"
        else
            echo "/usr/lib/systemd/user/$6"
        fi

        exit 0
        ;;
    "is-enabled virtqemud.socket")
        echo enabled
        exit 0
        ;;
    "is-active virtqemud.socket")
        if [ "${STUB_FAILS:-0}" = 1 ]; then
            echo "Failed to connect to bus: stub" >&2
            exit 4
        fi

        echo active
        exit 0
        ;;
    "--user is-enabled "* | "--user is-active "*)
        if [ "${STUB_FAILS:-0}" = 1 ]; then
            echo "Failed to connect to bus: stub" >&2
            exit 4
        fi

        case "$2" in
            is-enabled)
                echo disabled
                exit 1
                ;;
            is-active)
                echo inactive
                exit 3
                ;;
        esac
        ;;
    "--user edit "*)
        cat > /dev/null
        ;;
esac

if [ "${STUB_FAILS:-0}" = 1 ]; then
    echo "Failed: stub refused systemctl $*" >&2
    exit 1
fi

echo "stub systemctl $*"
STUB
    cat > "$dir/bin/getcap" << 'STUB'
#!/usr/bin/bash
if [ "${STUB_FAILS:-0}" = 1 ]; then
    exit 0
fi

exec /usr/sbin/getcap "$@"
STUB
    chmod 755 "$dir/bin/sudo" "$dir/bin/gdbus" "$dir/bin/systemctl" "$dir/bin/getcap"
}

# run_recipe_as_nobody <stubs> <recipe> <action>: the recipe's output; its
# status is the command's. The home under <stubs> is nobody's. RECIPE_INPUT
# is its stdin, by default the answers to setup-sunshine's credentials
# prompt (user, password, password again).
run_recipe_as_nobody() {
    local dir=$1 recipe=$2 action=$3

    setpriv --reuid=99 --regid=99 --clear-groups \
        env PATH="$dir/bin:$PATH" HOME="$dir/home" STUB_FAILS="${STUB_FAILS:-0}" \
        STUB_FRAGMENT_IN_HOME="${STUB_FRAGMENT_IN_HOME:-0}" \
        just --justfile "$MASTER" "$recipe" "$action" 2>&1 \
        <<< "${RECIPE_INPUT-$'alice\nsecret\nsecret'}"
}

# setup-sunshine virtual-monitor edits the user's apps.json through jq: a
# readable file gains the app, a file jq cannot read is left as it is and
# the recipe stops with `ERROR:`. Known-bad: jq's empty output replaced the
# user's file, and the recipe reported the app added.
check_sunshine_virtual_monitor_keeps_a_bad_apps_json() {
    local dir=$1 apps=$1/home/.config/sunshine/apps.json
    local recipe="ujust setup-sunshine virtual-monitor" output before after

    rm -rf "$dir/home/.config"

    if output=$(run_recipe_as_nobody "$dir" setup-sunshine virtual-monitor) \
        && grep -q "Added/updated 'Virtual Monitor'" <<< "$output" \
        && jq -e '.apps[] | select(.name == "Virtual Monitor")' "$apps" > /dev/null 2>&1; then
        echo "OK: $recipe adds the app to a readable apps.json"
    else
        echo "FAIL: $recipe on the seeded file: $(on_one_line 'no output' <<< "$output")"
    fi

    rm -rf "$dir/home/.config"
    mkdir -p "$(dirname "$apps")"
    printf '{"env": {}, "apps": [{"name": "Desktop"' > "$apps"
    chmod -R a+rwX "$dir/home/.config"
    before=$(sha256sum "$apps" || true)

    if output=$(run_recipe_as_nobody "$dir" setup-sunshine virtual-monitor); then
        echo "FAIL: $recipe exited 0 on a truncated apps.json:" \
            "$(on_one_line 'no output' <<< "$output")"
    elif ! grep -q "^ERROR: $apps not rewritten (jq: " <<< "$output" \
        || grep -q 'Added/updated' <<< "$output"; then
        echo "FAIL: $recipe on a truncated apps.json: $(on_one_line 'no output' <<< "$output")"
    else
        after=$(sha256sum "$apps" || true)

        if [ -n "$before" ] && [ "$before" = "$after" ]; then
            echo "OK: $recipe leaves a truncated apps.json as it was"
        else
            echo "FAIL: $recipe rewrote a truncated apps.json"
        fi
    fi
}

# check_recipe_stops_on_a_failed_call <stubs> <recipe> <action> <line>: the
# line the recipe prints after a call that succeeded, absent after one that
# failed, the status then 1.
check_recipe_stops_on_a_failed_call() {
    local dir=$1 recipe=$2 action=$3 line=$4
    local command="ujust $recipe${action:+ $action}" output

    rm -rf "$dir/home/.config"

    if output=$(run_recipe_as_nobody "$dir" "$recipe" "$action") \
        && grep -qF "$line" <<< "$output"; then
        echo "OK: $command prints '$line' after a call that succeeded"
    else
        echo "FAIL: $command on a call that succeeded: $(on_one_line 'no output' <<< "$output")"
    fi

    if output=$(STUB_FAILS=1 run_recipe_as_nobody "$dir" "$recipe" "$action"); then
        echo "FAIL: $command exited 0 after a call that failed:" \
            "$(on_one_line 'no output' <<< "$output")"
    elif grep -qF "$line" <<< "$output"; then
        echo "FAIL: $command printed '$line' after a call that failed:" \
            "$(on_one_line 'no output' <<< "$output")"
    else
        echo "OK: $command stops, without '$line', on a call that failed"
    fi
}

# setup-sunshine enable refuses a Sunshine unit loaded from the home, the
# copy Bazzite's Flatpak leaves there. Known-bad: the recipe enabled it.
check_sunshine_enable_refuses_a_home_unit() {
    local dir=$1
    local unit=$1/home/.config/systemd/user/app-dev.lizardbyte.app.Sunshine.service output

    if output=$(STUB_FRAGMENT_IN_HOME=1 run_recipe_as_nobody "$dir" setup-sunshine enable) \
        || ! grep -qF "ERROR: $unit shadows" <<< "$output" \
        || grep -qF 'Sunshine enabled for' <<< "$output"; then
        echo "FAIL: ujust setup-sunshine enable on a unit in the home:" \
            "$(on_one_line 'no output' <<< "$output")"
    else
        echo "OK: ujust setup-sunshine enable refuses a Sunshine unit loaded from the home"
    fi
}

# setup-sunshine enable limits the portal to this PC in a sunshine.conf
# without the key, leaves a value the user set, sets the portal's
# credentials through `sunshine --creds` when none exist, asking nothing once
# they do, refuses two passwords that differ, and restarts the unit so a
# running Sunshine reads the files only when it wrote one: each write alone
# (a host enabled on an older image, a first try with a mistyped password)
# takes the restart path, whose failure is the recipe's.
check_sunshine_enable_limits_the_portal() {
    local dir=$1 conf=$1/home/.config/sunshine/sunshine.conf output
    local state=$1/home/.config/sunshine/sunshine_state.json

    rm -rf "$dir/home/.config"

    if output=$(RECIPE_INPUT=$'alice\nsecret\nother' run_recipe_as_nobody "$dir" \
        setup-sunshine enable) || [ -e "$state" ]; then
        echo "FAIL: ujust setup-sunshine enable accepted two passwords that differ:" \
            "$(on_one_line 'no output' <<< "$output")"
    else
        echo "OK: ujust setup-sunshine enable refuses two passwords that differ"
    fi

    if output=$(run_recipe_as_nobody "$dir" setup-sunshine enable) \
        && [ "$(cat "$conf" 2> /dev/null)" = 'origin_web_ui_allowed = pc' ] \
        && grep -q '^stub systemctl --user restart ' <<< "$output" \
        && [ "$(jq -r .username "$state" 2> /dev/null)" = alice ]; then
        echo "OK: ujust setup-sunshine enable writes origin_web_ui_allowed = pc and the" \
            "credentials, and restarts on the credentials alone"
    else
        echo "FAIL: ujust setup-sunshine enable on a home with the limit and no credentials:" \
            "$(on_one_line 'no output' <<< "$output"); the file: $(cat "$conf" 2> /dev/null)"
    fi

    printf 'origin_web_ui_allowed = lan\n' > "$conf"

    if output=$(RECIPE_INPUT='' run_recipe_as_nobody "$dir" setup-sunshine enable) \
        && [ "$(cat "$conf")" = 'origin_web_ui_allowed = lan' ] \
        && grep -q '^stub systemctl --user enable --now ' <<< "$output" \
        && ! grep -q '^stub systemctl --user restart ' <<< "$output"; then
        echo "OK: ujust setup-sunshine enable leaves an origin_web_ui_allowed the user set," \
            "and a running Sunshine with nothing written"
    else
        echo "FAIL: ujust setup-sunshine enable rewrote the user's origin_web_ui_allowed," \
            "asked again for credentials or restarted with nothing written: $(cat "$conf");" \
            "$(on_one_line 'no output' <<< "$output")"
    fi

    rm -f "$conf"

    if output=$(STUB_FAILS=1 RECIPE_INPUT='' run_recipe_as_nobody "$dir" \
        setup-sunshine enable) \
        || ! grep -q 'stub refused systemctl --user enable app-' <<< "$output"; then
        echo "FAIL: ujust setup-sunshine enable with the limit alone written:" \
            "$(on_one_line 'no output' <<< "$output")"
    else
        echo "OK: ujust setup-sunshine enable takes the restart path on the limit alone," \
            "and stops when systemctl refuses"
    fi
}

# setup-sunshine status: one line for the unit, the words systemctl prints
# (the stub answers disabled, exit 1, and inactive, exit 3, as systemctl
# does; nothing, exit 4, under STUB_FAILS, as without a bus), one for the
# version, one for the capabilities (`none` when getcap prints none), and
# no ~/.config/sunshine written. Known-bad: `|| echo disabled` appended a
# second word under the one systemctl had printed, three lines for one; the
# version came from running `sunshine --version`, which creates
# ~/.config/sunshine before it prints (docs/gotchas.md § `sunshine --version`
# needs a home directory); the capabilities line was blank.
check_sunshine_status_lines() {
    local dir=$1
    local output

    rm -rf "$dir/home/.config"

    if output=$(run_recipe_as_nobody "$dir" setup-sunshine status) \
        && grep -qx 'app-dev.lizardbyte.app.Sunshine.service: disabled / inactive' <<< "$output" \
        && grep -qE '^Sunshine [0-9]{4}\.[0-9]+\.[0-9]+$' <<< "$output" \
        && grep -qE '^capabilities: [^ ]+$' <<< "$output" \
        && [ ! -e "$dir/home/.config/sunshine" ]; then
        echo "OK: ujust setup-sunshine status prints the unit state, the version and the" \
            "capabilities, a line each, and writes no ~/.config/sunshine"
    else
        echo "FAIL: ujust setup-sunshine status: $(on_one_line 'no output' ';' <<< "$output");" \
            "the home's .config/sunshine: $(ls -A "$dir/home/.config/sunshine" 2> /dev/null \
                | on_one_line 'not written' ',')"
    fi

    output=$(STUB_FAILS=1 run_recipe_as_nobody "$dir" setup-sunshine status || true)

    if grep -qx 'app-dev.lizardbyte.app.Sunshine.service: unknown / unknown' <<< "$output" \
        && grep -qx 'capabilities: none' <<< "$output"; then
        echo "OK: ujust setup-sunshine status says unknown and none for answers it did not get"
    else
        echo "FAIL: ujust setup-sunshine status without answers:" \
            "$(on_one_line 'no output' ';' <<< "$output")"
    fi
}

# setup-virtualization status: the socket line carries the word systemctl
# prints, `unknown` when it prints none, the quickemu line a version.
# Known-bad: an is-active that printed nothing left `enabled ()`.
check_virtualization_status_lines() {
    local dir=$1
    local output

    if output=$(run_recipe_as_nobody "$dir" setup-virtualization status) \
        && grep -q 'virtqemud.socket enabled (active)$' <<< "$output" \
        && grep -qE '^ +quickemu [0-9]+\.[0-9]+' <<< "$output"; then
        echo "OK: ujust setup-virtualization status prints the socket state and quickemu's version"
    else
        echo "FAIL: ujust setup-virtualization status: $(on_one_line 'no output' ';' <<< "$output")"
    fi

    output=$(STUB_FAILS=1 run_recipe_as_nobody "$dir" setup-virtualization status || true)

    if grep -q 'virtqemud.socket enabled (unknown)$' <<< "$output"; then
        echo "OK: ujust setup-virtualization status says unknown for an is-active without answer"
    else
        echo "FAIL: ujust setup-virtualization status without an is-active answer:" \
            "$(on_one_line 'no output' ';' <<< "$output")"
    fi
}

# Every recipe that takes an ACTION, the two replacing files' included,
# answers `Unknown option:` and fails on one it does not know, before any
# call. Known-bad: setup-panels ran on any argument.
check_recipes_reject_an_unknown_option() {
    local dir=$1
    local recipe output failed=""

    for recipe in $OUR_RECIPES $REPLACING_RECIPES; do
        if output=$(run_recipe_as_nobody "$dir" "$recipe" no-such-option) \
            || ! grep -q '^Unknown option: no-such-option' <<< "$output"; then
            failed+=" $recipe"
        fi
    done

    if [ -z "$failed" ]; then
        echo "OK: every recipe refuses an unknown option with Unknown option: and a non-zero exit"
    else
        echo "FAIL: recipes that run on an unknown option:$failed"
    fi
}

# The three recipes with a Choose menu exit 0 and print no `Unknown option:`
# when the menu answers nothing, as on a cancel or without a terminal.
# Known-bad: the empty answer fell to `*)`, `Unknown option:` and exit 1.
check_menu_recipes_accept_an_empty_answer() {
    local dir=$1
    local recipe output failed=""

    for recipe in setup-msi setup-sunshine setup-virtualization; do
        if ! output=$(STUB_FAILS=1 run_recipe_as_nobody "$dir" "$recipe" "") \
            || grep -q '^Unknown option:' <<< "$output"; then
            failed+=" $recipe"
        fi
    done

    if [ -z "$failed" ]; then
        echo "OK: every menu recipe exits 0 without Unknown option: on an empty answer"
    else
        echo "FAIL: menu recipes that reject an empty answer:$failed"
    fi
}

# --- main ---------------------------------------------------------------------

check_our_recipe_file
check_master_justfile
check_replacing_files
check_help

check_self_test 70-justfile.sh bash "$CTX/build_files/70-justfile.sh"

stubs=$(mktemp -d)
fixture_recipe_stubs "$stubs"
check_recipe_stops_on_a_failed_call "$stubs" setup-msi enable Done.
check_recipe_stops_on_a_failed_call "$stubs" setup-panels "" "stub applied the panels"
check_recipe_stops_on_a_failed_call "$stubs" setup-sunshine enable "Sunshine enabled for"
check_recipe_stops_on_a_failed_call "$stubs" setup-sunshine disable "Sunshine disabled for"
check_sunshine_enable_refuses_a_home_unit "$stubs"
check_sunshine_enable_limits_the_portal "$stubs"
check_sunshine_virtual_monitor_keeps_a_bad_apps_json "$stubs"
check_sunshine_status_lines "$stubs"
check_virtualization_status_lines "$stubs"
check_recipes_reject_an_unknown_option "$stubs"
check_menu_recipes_accept_an_empty_answer "$stubs"
rm -rf "$stubs"
