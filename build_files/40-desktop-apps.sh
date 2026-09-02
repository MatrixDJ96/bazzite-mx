#!/usr/bin/env bash
# Desktop applications that need the image layer: Firefox from Fedora with
# its Flatpak denied, gparted, and 1Password from its own repository. The two
# 1Password groups are created here, before the install, at fixed gids.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

dnf5 -y install firefox firefox-langpacks gparted
[ -x /usr/bin/firefox ] || die "/usr/bin/firefox missing after install"

deny_flatpak 'org.mozilla.firefox/*'

ONEPASSWORD_REPO=/etc/yum.repos.d/1password.repo
VENDORED_REPO=$CTX/system_files/etc/yum.repos.d/1password.repo

assert_key_fingerprint /etc/pki/rpm-gpg/RPM-GPG-KEY-1password
[ "$(readlink /opt)" = var/opt ] || die "/opt is not the var/opt symlink this script expects"
mkdir -p /var/opt
# Above 1000, which the application requires, and far from where useradd
# allocates: the same ids NixOS reserves (docs/gotchas.md).
ONEPASSWORD_GID=31001
ONEPASSWORD_MCP_GID=31002
groupadd --gid "$ONEPASSWORD_GID" onepassword
groupadd --gid "$ONEPASSWORD_MCP_GID" onepassword-mcp
install_from_repo 1password 1password

# The %post rewrote the .repo: the vendored copy goes back on a fresh inode.
install -m 0644 "$VENDORED_REPO" "$ONEPASSWORD_REPO"
cmp -s "$VENDORED_REPO" "$ONEPASSWORD_REPO" || die "$ONEPASSWORD_REPO differs from the vendored copy after the restore"
grep -qx 'enabled=0' "$ONEPASSWORD_REPO" || die "$ONEPASSWORD_REPO is not disabled"

[ -d /var/opt/1Password ] || die "/var/opt/1Password missing after install"
[ "$(readlink /usr/bin/1password)" = /opt/1Password/1password ] || die "/usr/bin/1password does not point into /opt/1Password"
for spec in "onepassword=$ONEPASSWORD_GID" "onepassword-mcp=$ONEPASSWORD_MCP_GID"; do
    g=${spec%%=*}
    want=${spec#*=}
    gid=$(awk -F: -v g="$g" '$1 == g { print $3 }' /etc/group)
    [ -n "$gid" ] || die "group $g missing after install"
    [ "$gid" = "$want" ] || die "group $g has gid $gid, not $want"
done
for spec in "1Password-BrowserSupport=$ONEPASSWORD_GID" "1password-mcp=$ONEPASSWORD_MCP_GID"; do
    bin=${spec%%=*}
    want=${spec#*=}
    st=$(stat -c '%g %A' "/var/opt/1Password/$bin")
    [ "$st" = "$want -rwxr-sr-x" ] || die "/var/opt/1Password/$bin is '$st', not setgid to $want"
done

POLICY=/usr/share/polkit-1/actions/com.1password.1Password.policy
[ -f "$POLICY" ] || die "$POLICY missing: the %post did not install the polkit actions"
xmllint --noout "$POLICY" || die "$POLICY is not well-formed XML"
for action in unlock authorizeCLI authorizeSshAgent; do
    grep -q "action id=\"com.1password.1Password.$action\"" "$POLICY" || die "$POLICY lacks action com.1password.1Password.$action"
done
! grep -q 'unix-user:' "$POLICY" || die "$POLICY names a build-time user as owner: $(grep -o 'unix-user:[^ <]*' "$POLICY" | tr '\n' ' ')"

log "desktop-apps: firefox $(rpm -q --qf '%{VERSION}' firefox), gparted $(rpm -q --qf '%{VERSION}' gparted), 1password $(rpm -q --qf '%{VERSION}' 1password); Firefox Flatpak denied in $FLATPAK_BLOCKLIST"
