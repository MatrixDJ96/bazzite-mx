#!/usr/bin/bash
# MX block 45: Firefox from Mozilla's official RPM repo (replaces
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
# Catches the Fedora rpm before the Mozilla install resolves to the
# wrong provider. Gate the remove on `rpm -q` rather than `|| true`:
# "not installed" is an explicit skip, while a real `dnf5 remove`
# failure still fails the build.
for pkg in firefox firefox-langpacks; do
    if rpm -q "$pkg" &>/dev/null; then
        dnf5 -y remove "$pkg"
    fi
done

### Section 2: install Firefox + Italian langpack from Mozilla repo ###
# Extend the language list by adding firefox-l10n-<code> below.
dnf5 -y --enablerepo=mozilla install \
    firefox \
    firefox-l10n-it

echo "::endgroup::"
