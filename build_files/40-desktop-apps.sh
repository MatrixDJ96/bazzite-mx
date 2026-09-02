#!/usr/bin/env bash
# Desktop applications that need the image layer: Firefox from Fedora with
# its Flatpak denied, gparted, and 1Password from its own repository. The two
# 1Password groups are created here, before the install, at fixed gids.
#
# Usage: run by build.sh; no arguments.
# Writes: the packages; the Firefox Flatpak denied in the base's Flatpak
#   filter; the groups onepassword and onepassword-mcp; the vendored
#   1password.repo put back after the %post rewrote it.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

ONEPASSWORD_REPO=/etc/yum.repos.d/1password.repo
VENDORED_REPO=$CTX/system_files/etc/yum.repos.d/1password.repo
ONEPASSWORD_DIR=/var/opt/1Password
POLKIT_POLICY=/usr/share/polkit-1/actions/com.1password.1Password.policy

# Above 1000, which the application requires, and far from where useradd
# allocates: the same ids NixOS reserves (docs/gotchas.md).
ONEPASSWORD_GID=31001
ONEPASSWORD_MCP_GID=31002

# --- the steps ----------------------------------------------------------------

install_firefox_and_gparted() {
    dnf5 -y install firefox firefox-langpacks gparted

    if [ ! -x /usr/bin/firefox ]; then
        fail_build "/usr/bin/firefox missing after install"
    fi

    deny_flatpak 'org.mozilla.firefox/*'
}

# The package unpacks under /opt, a link to var/opt that a build lacks; the
# %post rewrites the .repo with enabled=1, so the vendored copy goes back on
# a fresh inode (docs/conventions.md § Build scripts).
install_onepassword() {
    assert_key_fingerprint /etc/pki/rpm-gpg/RPM-GPG-KEY-1password

    if [ "$(readlink /opt)" != var/opt ]; then
        fail_build "/opt is not the var/opt symlink this script expects"
    fi

    mkdir -p /var/opt
    groupadd --gid "$ONEPASSWORD_GID" onepassword
    groupadd --gid "$ONEPASSWORD_MCP_GID" onepassword-mcp
    install_from_repo 1password 1password

    install -m 0644 "$VENDORED_REPO" "$ONEPASSWORD_REPO"

    if ! cmp -s "$VENDORED_REPO" "$ONEPASSWORD_REPO"; then
        fail_build "$ONEPASSWORD_REPO differs from the vendored copy after the restore"
    fi

    if ! grep -qx 'enabled=0' "$ONEPASSWORD_REPO"; then
        fail_build "$ONEPASSWORD_REPO is not disabled"
    fi
}

require_onepassword_layout() {
    if [ ! -d "$ONEPASSWORD_DIR" ]; then
        fail_build "$ONEPASSWORD_DIR missing after install"
    fi

    if [ "$(readlink /usr/bin/1password)" != /opt/1Password/1password ]; then
        fail_build "/usr/bin/1password does not point into /opt/1Password"
    fi
}

# The %post must have kept the groups created above, at their gids.
require_onepassword_groups() {
    local spec group wanted_gid gid

    for spec in "onepassword=$ONEPASSWORD_GID" "onepassword-mcp=$ONEPASSWORD_MCP_GID"; do
        group=${spec%%=*}
        wanted_gid=${spec#*=}
        gid=$(awk -F: -v g="$group" '$1 == g { print $3 }' /etc/group)

        if [ -z "$gid" ]; then
            fail_build "group $group missing after install"
        fi

        if [ "$gid" != "$wanted_gid" ]; then
            fail_build "group $group has gid $gid, not $wanted_gid"
        fi
    done
}

# The browser and MCP helpers run setgid to their group: that is what the
# fixed gids are for.
require_onepassword_setgid_helpers() {
    local spec helper wanted_gid mode

    for spec in "1Password-BrowserSupport=$ONEPASSWORD_GID" "1password-mcp=$ONEPASSWORD_MCP_GID"; do
        helper=${spec%%=*}
        wanted_gid=${spec#*=}
        mode=$(stat -c '%g %A' "$ONEPASSWORD_DIR/$helper")

        if [ "$mode" != "$wanted_gid -rwxr-sr-x" ]; then
            fail_build "$ONEPASSWORD_DIR/$helper is '$mode', not setgid to $wanted_gid"
        fi
    done
}

# The polkit actions must exist, parse, and name no build-time user: a
# `unix-user:` owner written by the %post would be a user no host has.
require_polkit_actions() {
    local action owners

    if [ ! -f "$POLKIT_POLICY" ]; then
        fail_build "$POLKIT_POLICY missing: the %post did not install the polkit actions"
    fi

    if ! xmllint --noout "$POLKIT_POLICY"; then
        fail_build "$POLKIT_POLICY is not well-formed XML"
    fi

    for action in unlock authorizeCLI authorizeSshAgent; do
        if ! grep -q "action id=\"com.1password.1Password.$action\"" "$POLKIT_POLICY"; then
            fail_build "$POLKIT_POLICY lacks action com.1password.1Password.$action"
        fi
    done

    if grep -q 'unix-user:' "$POLKIT_POLICY"; then
        owners=$(grep -o 'unix-user:[^ <]*' "$POLKIT_POLICY" | tr '\n' ' ')
        fail_build "$POLKIT_POLICY names a build-time user as owner: $owners"
    fi
}

# --- main ---------------------------------------------------------------------

install_firefox_and_gparted
install_onepassword
require_onepassword_layout
require_onepassword_groups
require_onepassword_setgid_helpers
require_polkit_actions

firefox_version=$(rpm -q --qf '%{VERSION}' firefox)
gparted_version=$(rpm -q --qf '%{VERSION}' gparted)
onepassword_version=$(rpm -q --qf '%{VERSION}' 1password)
log "desktop-apps: firefox $firefox_version, gparted $gparted_version," \
    "1password $onepassword_version; Firefox Flatpak denied in $FLATPAK_BLOCKLIST"
