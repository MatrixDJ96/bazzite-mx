#!/usr/bin/env bash
# Desktop applications that need the image layer: Firefox from Fedora with
# its Flatpak denied and Bazzite's defaults, gparted, and 1Password from its
# own repository. The two 1Password groups are created here, before the
# install, at fixed gids.
#
# Usage: run by build.sh; no arguments.
# Writes: the packages; the Firefox Flatpak denied in the base's Flatpak
#   filter; Bazzite's Firefox defaults in the RPM's preferences; the groups
#   onepassword and onepassword-mcp; the vendored 1password.repo put back
#   after the %post rewrote it.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

ONEPASSWORD_REPO=/etc/yum.repos.d/1password.repo
VENDORED_REPO=$CTX/system_files/etc/yum.repos.d/1password.repo
# Bazzite copies this file into the Flatpak only; the RPM reads its own directory.
BAZZITE_FIREFOX_PREFS=/usr/share/ublue-os/firefox-config/01-bazzite-global.js
FIREFOX_PREFS_DIR=/usr/lib64/firefox/browser/defaults/preferences

# Above 1000, since the 1Password app rejects a BrowserSupport whose group id is
# below 1000, and far from where useradd allocates.
ONEPASSWORD_GID=31001
ONEPASSWORD_MCP_GID=31002

# --- the steps ----------------------------------------------------------------

install_firefox_and_gparted() {
    dnf5 -y install firefox firefox-langpacks gparted
    install -m 0644 "$BAZZITE_FIREFOX_PREFS" "$FIREFOX_PREFS_DIR/"
    deny_flatpak 'org.mozilla.firefox/*'
}

# The package unpacks under /opt, a link to var/opt that a build lacks; the
# %post rewrites the .repo with enabled=1, so the vendored copy goes back, on a
# fresh inode, before the repository gate compares it byte for byte.
install_onepassword() {
    assert_key_fingerprint /etc/pki/rpm-gpg/RPM-GPG-KEY-1password

    mkdir -p /var/opt
    groupadd --gid "$ONEPASSWORD_GID" onepassword
    groupadd --gid "$ONEPASSWORD_MCP_GID" onepassword-mcp
    install_from_repo 1password 1password

    install -m 0644 "$VENDORED_REPO" "$ONEPASSWORD_REPO"
}

# --- main ---------------------------------------------------------------------

install_firefox_and_gparted
install_onepassword

firefox_version=$(rpm -q --qf '%{VERSION}' firefox)
gparted_version=$(rpm -q --qf '%{VERSION}' gparted)
onepassword_version=$(rpm -q --qf '%{VERSION}' 1password)
log "desktop-apps: firefox $firefox_version, gparted $gparted_version," \
    "1password $onepassword_version; Firefox Flatpak denied in $FLATPAK_BLOCKLIST"
