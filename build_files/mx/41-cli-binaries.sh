#!/usr/bin/bash
# MX block 41: precompiled CLI binaries from official releases.
# Pinned upstream releases, installed into /usr/bin (0755). /tmp is
# tmpfs at build time.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

GH_VERSION=2.94.0
GLAB_VERSION=1.102.0
SHELLCHECK_VERSION=0.11.0
SHFMT_VERSION=3.13.1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

### gh ###
# Keep the upstream archive filename so the checksum entry matches.
curl -fsSL -O \
    "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz"
curl -fsSL -o gh_checksums.txt \
    "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt"
sha256sum --ignore-missing -c gh_checksums.txt
tar -xzf "gh_${GH_VERSION}_linux_amd64.tar.gz"
install -m 0755 "gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/bin/gh

### glab ###
curl -fsSL -O \
    "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_amd64.tar.gz"
curl -fsSL -o glab_checksums.txt \
    "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/checksums.txt"
sha256sum --ignore-missing -c glab_checksums.txt
tar -xzf "glab_${GLAB_VERSION}_linux_amd64.tar.gz"
install -m 0755 bin/glab /usr/bin/glab

### shellcheck ###
# No upstream checksum file: verify non-empty + executable + version pin.
curl -fsSL -o shellcheck.tar.xz \
    "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz"
tar -xJf shellcheck.tar.xz
install -m 0755 "shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/bin/shellcheck
[ -s /usr/bin/shellcheck ]
/usr/bin/shellcheck --version | grep -qF "version: ${SHELLCHECK_VERSION}"

### shfmt ###
# Raw binary, no upstream checksum: verify non-empty + executable + version pin.
curl -fsSL -o shfmt \
    "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_amd64"
install -m 0755 shfmt /usr/bin/shfmt
[ -s /usr/bin/shfmt ]
/usr/bin/shfmt --version | grep -qF "v${SHFMT_VERSION}"

echo "::endgroup::"
