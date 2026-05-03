#!/usr/bin/bash
# MX block 45: Firefox from Mozilla's official RPM repo.
#
# Bazzite installs Firefox as a Flathub flatpak (org.mozilla.firefox)
# by default. We replace it with Mozilla's official RPM build for two
# practical reasons:
#  1. Native browser-host integration (e.g. 1Password native messaging
#     works out-of-the-box; the flatpak requires socket workarounds for
#     host integration).
#  2. Guaranteed alignment with system libraries (glibc, mesa, ...),
#     no flatpak runtime drifting from the base image.
#
# Build-time: the vendored .repo ships enabled=0 and --enablerepo=mozilla
# is the runtime override (same pattern as gh-cli, docker-ce, vscode).
# The .repo declares priority=10: even if both repos accidentally got
# enabled (mozilla + fedora) during a future install, dnf5-priorities
# would let Mozilla win.
#
# Companion Phase 8 changes (later commit, not in this file):
#  - system-flatpaks.list override: don't auto-install
#    org.mozilla.firefox on first boot
#  - flatpak-blocklist extension: hides org.mozilla.firefox from
#    GUI stores (Discover/Bazaar) to prevent accidental reinstall
#  - system-setup + user-setup hooks: remove a pre-existing Firefox
#    flatpak for users upgrading from a pre-Mozilla-RPM bazzite-mx

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

### Section 1: remove any pre-existing Fedora-repo firefox ###
# Bazzite doesn't install firefox as rpm by default (only flatpak),
# but if upstream ever changes that — or if one of the two packages
# is present and the other isn't — this loop catches the Fedora rpm
# before our Mozilla install resolves to the wrong provider.
# Pattern: gate the remove on `rpm -q` instead of `|| true`. The
# "not installed" case is an explicit skip, while a real `dnf5 remove`
# failure (db corruption, dep deadlock) is not masked and fails the
# build via `set -euxo pipefail`.
for pkg in firefox firefox-langpacks; do
    if rpm -q "$pkg" &>/dev/null; then
        dnf5 -y remove "$pkg"
    fi
done

### Section 2: install Firefox + Italian langpack from Mozilla repo ###
# firefox-l10n-it is the Italian langpack in Mozilla's format
# (firefox-l10n-<lang>). To extend the language list: add
# firefox-l10n-<code> to the install line below.
dnf5 -y --enablerepo=mozilla install \
    firefox \
    firefox-l10n-it

echo "::endgroup::"
