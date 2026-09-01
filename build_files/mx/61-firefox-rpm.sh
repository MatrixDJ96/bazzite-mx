#!/usr/bin/bash
# MX block 61: Firefox from Mozilla's official RPM repo (replaces
# Bazzite's org.mozilla.firefox flatpak) for native browser-host
# integration (e.g. 1Password native messaging) and system-library
# alignment.
#
# The vendored .repo ships enabled=0; --enablerepo=mozilla is the
# runtime override. It declares priority=10 so Mozilla wins even if
# both mozilla + fedora repos were enabled during a future install.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

### Section 1: remove any pre-existing Fedora-repo firefox ###
# A no-op on the current base and has been since bazzite e8a685c7 +
# c40293f5 consolidated the removals: build_files/global-remove strips
# `firefox{,-langpacks}` on every variant, and neither is installed in
# 44.20260831 (MEASURED 2026-09-01). Kept as a guard, not as a live step --
# upstream has flipped this before, and the Mozilla install below would
# otherwise resolve `firefox` to the wrong provider. Gate the remove on
# `rpm -q` rather than `|| true`: "not installed" is an explicit skip, while
# a real `dnf5 remove` failure still fails the build.
for pkg in firefox firefox-langpacks; do
    if rpm -q "$pkg" &>/dev/null; then
        dnf5 -y remove "$pkg"
    fi
done

### Section 2: install Firefox + Italian langpack from Mozilla repo ###
# Extend the language list by adding firefox-l10n-<code> below.
dnf5 -y install --enablerepo=mozilla \
    firefox \
    firefox-l10n-it

echo "::endgroup::"
