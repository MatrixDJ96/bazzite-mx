#!/usr/bin/env bash
# Command-line tools from Fedora, none of them in the base, and shfmt from its
# latest GitHub release: Fedora retired the package (releng ticket 13259).
#
# Usage: run by build.sh; no arguments.
# Writes: the packages listed below and /usr/bin/shfmt.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

SHFMT_LATEST_URL=https://github.com/mvdan/sh/releases/latest
SHFMT_BIN=/usr/bin/shfmt

dnf_retry -y install \
    ShellCheck \
    android-tools \
    bcc \
    bcc-tools \
    bpftop \
    bpftrace \
    ccache \
    flatpak-builder \
    gh \
    glab \
    iotop-c \
    nicstat \
    numactl \
    ripgrep \
    sysprof \
    telnet \
    trace-cmd

# The release publishes no checksum file: integrity is TLS to GitHub, and the
# binary must report the tag it was downloaded from.
shfmt_tag=$(curl -fsSL --retry 3 --retry-delay 5 -o /dev/null -w '%{url_effective}' \
    "$SHFMT_LATEST_URL")
shfmt_tag=${shfmt_tag##*/}

if [[ ! "$shfmt_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail_build "shfmt: $SHFMT_LATEST_URL resolved to no release tag ('$shfmt_tag')"
fi

curl -fsSL --retry 3 --retry-delay 5 -o "$BUILD_TMP/shfmt" \
    "https://github.com/mvdan/sh/releases/download/$shfmt_tag/shfmt_${shfmt_tag}_linux_amd64"
install -m 0755 "$BUILD_TMP/shfmt" "$SHFMT_BIN"

if [ "$("$SHFMT_BIN" --version 2> /dev/null)" != "$shfmt_tag" ]; then
    fail_build "shfmt: $SHFMT_BIN does not report $shfmt_tag"
fi

gh_version=$(rpm -q --qf '%{VERSION}' gh)
glab_version=$(rpm -q --qf '%{VERSION}' glab)
shellcheck_version=$(rpm -q --qf '%{VERSION}' ShellCheck)
log "cli-rpms: gh $gh_version, glab $glab_version, shellcheck $shellcheck_version," \
    "shfmt $shfmt_tag"
