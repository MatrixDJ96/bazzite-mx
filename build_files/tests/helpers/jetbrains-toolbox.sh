#!/usr/bin/env bash
# Smoke test of /usr/libexec/bazzite-mx-jetbrains-toolbox, the helper behind
# ujust install-jetbrains-toolbox: latest, install, status and a second
# install against a packed tarball and a `file://` release feed; the tarballs
# and the feeds upstream could ship broken, a Toolbox someone else unpacked
# at the same path, the first start and an install while Toolbox runs.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=../lib.sh
source "$(dirname "$(realpath "$0")")/../lib.sh"

TOOLBOX=/usr/libexec/bazzite-mx-jetbrains-toolbox

# --- the fixtures -------------------------------------------------------------

# fixture_toolbox_tree <dir>: the unpacked layout upstream ships, build 9.9.9.
fixture_toolbox_tree() {
    local dir=$1
    local bin=$dir/jetbrains-toolbox-9.9.9/bin

    rm -rf "$dir/jetbrains-toolbox-9.9.9"
    mkdir -p "$bin"
    printf '#!/bin/sh\necho toolbox\n' > "$bin/jetbrains-toolbox"
    chmod 755 "$bin/jetbrains-toolbox"
    printf '9.9.9\n' > "$bin/build.txt"
}

# fixture_toolbox_pack <dir> [<top directory>]: the tarball and the checksum
# file good.sha256 that matches it.
fixture_toolbox_pack() {
    local dir=$1
    local top=${2:-jetbrains-toolbox-9.9.9}
    local checksum

    tar czf "$dir/jetbrains-toolbox-9.9.9.tar.gz" -C "$dir" "$top"
    checksum=$(sha256sum "$dir/jetbrains-toolbox-9.9.9.tar.gz" | cut -d' ' -f1 || true)
    printf '%s *jetbrains-toolbox-9.9.9.tar.gz\n' "$checksum" > "$dir/good.sha256"
}

# fixture_toolbox_feed <dir> <feed file> <build> [<checksum file>]: the
# release feed in upstream's shape, without the checksum link when no
# checksum file is given.
fixture_toolbox_feed() {
    local dir=$1
    local feed=$2
    local build=$3
    local checksum_file=${4:-}
    local link="file://$dir/jetbrains-toolbox-9.9.9.tar.gz"
    local downloads="\"link\":\"$link\""

    if [ -n "$checksum_file" ]; then
        downloads+=",\"checksumLink\":\"file://$dir/$checksum_file\""
    fi

    printf '{"TBA":[{"build":"%s","downloads":{"linux":{%s}}}]}\n' "$build" "$downloads" \
        > "$dir/$feed"
}

# run_toolbox <dir> <feed file> <command>: the installer against the feed,
# with the fixture home and the file:// protocol allowed.
run_toolbox() {
    local dir=$1
    local feed=$2
    local command=$3

    HOME=$dir/home XDG_DATA_HOME='' XDG_CACHE_HOME='' NO_LAUNCH="${NO_LAUNCH:-1}" \
        CURL_PROTO='=https,file' \
        FEED_URL="file://$dir/$feed" "$TOOLBOX" "$command"
}

toolbox_reset_home() {
    local dir=$1

    rm -rf "$dir/home/.local" "$dir/home/.cache"
}

# --- the checks ---------------------------------------------------------------

check_toolbox_install() {
    local dir=$1
    local app=$dir/home/.local/share/JetBrains/ToolboxApp
    local download=$dir/home/.cache/bazzite-mx/jetbrains-toolbox/jetbrains-toolbox-9.9.9.tar.gz
    local output

    output=$(run_toolbox "$dir" feed-good.json latest 2>&1 || true)

    if grep -q '^build 9.9.9$' <<< "$output"; then
        echo "OK: toolbox latest reads the feed"
    else
        echo "FAIL: toolbox latest: $(head -n2 <<< "$output" | on_one_line 'no output')"
    fi

    if output=$(run_toolbox "$dir" feed-wrong.json install 2>&1); then
        echo "FAIL: toolbox installer accepted a wrong sha256"
    elif grep -q 'sha256 mismatch' <<< "$output" && [ ! -e "$app" ] && [ ! -e "$download" ]; then
        echo "OK: toolbox installer refuses a wrong sha256, installs nothing, drops the download"
    else
        echo "FAIL: toolbox installer on a wrong sha256:" \
            "$(tail -n1 <<< "$output" | on_one_line 'no output');" \
            "$(find "$dir/home" -type f | on_one_line none)"
    fi

    if output=$(run_toolbox "$dir" feed-good.json install 2>&1) \
        && [ -x "$app/bin/jetbrains-toolbox" ] && [ "$(cat "$app/bin/build.txt")" = 9.9.9 ]; then
        echo "OK: toolbox installer unpacks the verified build ($(tail -n1 <<< "$output"))"
    else
        echo "FAIL: toolbox installer on the good feed:" \
            "$(tail -n2 <<< "$output" | on_one_line 'no output')"
    fi

    output=$(run_toolbox "$dir" feed-good.json status 2>&1 || true)

    if grep -q '^installed: build 9.9.9 at ' <<< "$output"; then
        echo "OK: toolbox status reports the installed build"
    else
        echo "FAIL: toolbox status: $(head -n1 <<< "$output" | on_one_line 'no output')"
    fi

    output=$(run_toolbox "$dir" feed-good.json install 2>&1 || true)

    if grep -q 'already installed' <<< "$output"; then
        echo "OK: toolbox installer is idempotent on the same build"
    else
        echo "FAIL: toolbox second install: $(tail -n1 <<< "$output" | on_one_line 'no output')"
    fi
}

# After the unpack the installer starts the app once through setsid, a stub
# first on PATH here that records its arguments instead of launching the
# fixture binary.
check_toolbox_starts_the_app_once() {
    local dir=$1
    local stubs=$dir/setsid-stub
    local app=$dir/home/.local/share/JetBrains/ToolboxApp
    local output

    fixture_toolbox_tree "$dir"
    fixture_toolbox_pack "$dir"
    mkdir -p "$stubs"
    printf '#!/usr/bin/bash\necho "$*" > %s/called\n' "$stubs" > "$stubs/setsid"
    chmod 755 "$stubs/setsid"

    toolbox_reset_home "$dir"

    if output=$(PATH="$stubs:$PATH" NO_LAUNCH=0 run_toolbox "$dir" feed-good.json install 2>&1) \
        && grep -qxF -- "-f $app/bin/jetbrains-toolbox" "$stubs/called" 2> /dev/null; then
        echo "OK: toolbox installer starts the app once after the unpack"
    else
        echo "FAIL: toolbox installer on a start that succeeded:" \
            "$(tail -n2 <<< "$output" | on_one_line 'no output')"
    fi

    rm -rf "$stubs"
}

# Known-bad: an install while the Toolbox the helper started is still
# running, a process carrying the binary's path in its command line.
check_toolbox_refuses_while_running() {
    local dir=$1
    local app=$dir/home/.local/share/JetBrains/ToolboxApp
    local pid

    fixture_toolbox_tree "$dir"
    fixture_toolbox_pack "$dir"
    (exec -a "$app/bin/jetbrains-toolbox" sleep 60) &
    pid=$!

    # The child execs on its own time: until then pgrep sees the test's command line.
    for _ in {1..50}; do
        pgrep -f "$app/bin/jetbrains-toolbox" > /dev/null && break
        sleep 0.1
    done

    check_toolbox_refuses "$dir" feed-good.json 'quit it first' 'an install while Toolbox runs'
    kill "$pid"
    wait "$pid" 2> /dev/null || true
}

# A Toolbox unpacked at the same path by something else (an earlier recipe,
# a hand install) carries upstream's bin/build.txt and nothing of ours:
# status reports it and install leaves it alone.
check_toolbox_foreign_install() {
    local dir=$1
    local app=$dir/home/.local/share/JetBrains/ToolboxApp
    local download=$dir/home/.cache/bazzite-mx/jetbrains-toolbox/jetbrains-toolbox-9.9.9.tar.gz
    local output

    toolbox_reset_home "$dir"
    mkdir -p "$app"
    cp -a "$dir/jetbrains-toolbox-9.9.9/bin" "$app/"

    output=$(run_toolbox "$dir" feed-good.json status 2>&1 || true)

    if grep -q '^installed: build 9.9.9 at ' <<< "$output"; then
        echo "OK: toolbox status reads the build of a Toolbox it did not unpack (bin/build.txt)"
    else
        echo "FAIL: toolbox status on a foreign Toolbox:" \
            "$(head -n1 <<< "$output" | on_one_line 'no output')"
    fi

    output=$(run_toolbox "$dir" feed-good.json install 2>&1 || true)

    if grep -q 'already installed' <<< "$output" && [ ! -e "$download" ]; then
        echo "OK: toolbox installer leaves a foreign Toolbox of the same build alone"
    else
        echo "FAIL: toolbox install over a foreign Toolbox of the same build:" \
            "$(tail -n1 <<< "$output" | on_one_line 'no output')"
    fi
}

# check_toolbox_refuses <dir> <feed file> <message> <what>: the install is
# refused with the message and nothing lands under the home.
check_toolbox_refuses() {
    local dir=$1
    local feed=$2
    local message=$3
    local what=$4
    local app=$dir/home/.local/share/JetBrains/ToolboxApp
    local output

    toolbox_reset_home "$dir"

    if output=$(run_toolbox "$dir" "$feed" install 2>&1); then
        echo "FAIL: toolbox installer accepted $what"
    elif grep -q "$message" <<< "$output" && [ ! -e "$app" ] \
        && ! grep -qE '^(curl|jq|gzip|tar):' <<< "$output"; then
        echo "OK: toolbox installer refuses $what, no tool line of its own"
    else
        echo "FAIL: toolbox installer on $what: $(tail -n1 <<< "$output" | on_one_line 'no output')"
    fi
}

# Known-bad tarballs, first pair: upstream's bin/build.txt missing, the
# binary missing.
check_toolbox_refuses_broken_contents() {
    local dir=$1

    fixture_toolbox_tree "$dir"
    rm -f "$dir/jetbrains-toolbox-9.9.9/bin/build.txt"
    fixture_toolbox_pack "$dir"
    check_toolbox_refuses "$dir" feed-good.json 'bin/build.txt missing' \
        'a tarball without bin/build.txt'

    fixture_toolbox_tree "$dir"
    rm -rf "$dir/jetbrains-toolbox-9.9.9/bin"
    mkdir -p "$dir/jetbrains-toolbox-9.9.9/lib"
    fixture_toolbox_pack "$dir"
    check_toolbox_refuses "$dir" feed-good.json 'bin/jetbrains-toolbox missing' \
        'a tarball without bin/jetbrains-toolbox'
}

# Known-bad tarballs, second pair: another top directory, a binary without
# the execute bit.
check_toolbox_refuses_bad_shapes() {
    local dir=$1

    fixture_toolbox_tree "$dir"
    mv "$dir/jetbrains-toolbox-9.9.9" "$dir/toolbox-9.9.9"
    fixture_toolbox_pack "$dir" toolbox-9.9.9
    mv "$dir/toolbox-9.9.9" "$dir/jetbrains-toolbox-9.9.9"
    check_toolbox_refuses "$dir" feed-good.json 'unexpected top directory' \
        'a tarball with another top directory'

    fixture_toolbox_tree "$dir"
    chmod 644 "$dir/jetbrains-toolbox-9.9.9/bin/jetbrains-toolbox"
    fixture_toolbox_pack "$dir"
    check_toolbox_refuses "$dir" feed-good.json 'is not executable' \
        'a tarball whose binary is not executable'
}

# Known-bad feeds: no checksum link, a dead checksum link, a link naming
# another build, a checksum file that is not a sha256.
check_toolbox_refuses_bad_feeds() {
    local dir=$1

    fixture_toolbox_tree "$dir"
    fixture_toolbox_pack "$dir"
    printf 'not a checksum\n' > "$dir/garbage.sha256"
    fixture_toolbox_feed "$dir" feed-noshape.json 9.9.9
    fixture_toolbox_feed "$dir" feed-otherbuild.json 9.9.8 good.sha256
    fixture_toolbox_feed "$dir" feed-garbage.json 9.9.9 garbage.sha256
    fixture_toolbox_feed "$dir" feed-deadlink.json 9.9.9 missing.sha256

    check_toolbox_refuses "$dir" feed-noshape.json 'the feed lost its shape' \
        'a feed without the checksum link'
    check_toolbox_refuses "$dir" feed-deadlink.json 'cannot fetch the checksum file' \
        'a feed whose checksum link is dead'
    check_toolbox_refuses "$dir" feed-otherbuild.json 'does not name build 9.9.8' \
        'a link that names another build'
    check_toolbox_refuses "$dir" feed-garbage.json 'does not start with a sha256' \
        'a checksum file that is not a sha256'
}

# --- main ---------------------------------------------------------------------

toolbox=$(mktemp -d)
mkdir -p "$toolbox/home"
fixture_toolbox_tree "$toolbox"
fixture_toolbox_pack "$toolbox"
printf '%064d *jetbrains-toolbox-9.9.9.tar.gz\n' 0 > "$toolbox/wrong.sha256"
fixture_toolbox_feed "$toolbox" feed-good.json 9.9.9 good.sha256
fixture_toolbox_feed "$toolbox" feed-wrong.json 9.9.9 wrong.sha256
check_toolbox_install "$toolbox"
check_toolbox_foreign_install "$toolbox"
check_toolbox_refuses_broken_contents "$toolbox"
check_toolbox_refuses_bad_feeds "$toolbox"
check_toolbox_refuses_bad_shapes "$toolbox"
check_toolbox_starts_the_app_once "$toolbox"
check_toolbox_refuses_while_running "$toolbox"
rm -rf "$toolbox"
