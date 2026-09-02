#!/usr/bin/env bash
# Smoke test of 40-desktop-apps.sh: Firefox, gparted and 1Password. The
# Flatpak filter, the vendored 1Password repository and key, the polkit
# actions, the relocated groups and the /opt symlinks.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

KEY=/etc/pki/rpm-gpg/RPM-GPG-KEY-1password
ONEPASSWORD_REPO=/etc/yum.repos.d/1password.repo
POLICY=/usr/share/polkit-1/actions/com.1password.1Password.policy
ALLOWED_BROWSERS=/etc/1password/custom_allowed_browsers

# --- the applications ---------------------------------------------------------

check_applications() {
    local app

    check_pkg firefox firefox-langpacks gparted 1password

    for app in org.mozilla.firefox gparted com.onepassword.OnePassword; do
        check_desktop_file "/usr/share/applications/$app.desktop"
    done

    if [ -x /usr/bin/firefox ]; then
        echo "OK: /usr/bin/firefox executable"
    else
        echo "FAIL: /usr/bin/firefox missing"
    fi
}

# Our deny line once and last, the base's lines still there, nothing that is
# not a rule.
check_flatpak_blocklist() {
    local last_line not_a_rule lines

    check_flatpak_deny 'org.mozilla.firefox/*'

    last_line=$(tail -n1 "$FLATPAK_BLOCKLIST" 2>&1 || true)

    if [ "$last_line" = 'deny org.mozilla.firefox/*' ]; then
        echo "OK: $FLATPAK_BLOCKLIST: the Firefox deny line is last"
    else
        echo "FAIL: $FLATPAK_BLOCKLIST last line: ${last_line:-empty}"
    fi

    if grep -q '^deny com.valvesoftware.Steam/\*$' "$FLATPAK_BLOCKLIST" 2> /dev/null \
        && grep -q '^deny net.lutris.Lutris/\*$' "$FLATPAK_BLOCKLIST" 2> /dev/null; then
        echo "OK: $FLATPAK_BLOCKLIST keeps the base's deny lines (Steam, Lutris)"
    else
        lines=$(cat "$FLATPAK_BLOCKLIST" 2>&1 | tr '\n' ';' || true)
        echo "FAIL: $FLATPAK_BLOCKLIST lost the base's lines: ${lines:-empty}"
    fi

    not_a_rule=$(grep -vE '^(#|$|(allow|deny) [^ ]+$)' "$FLATPAK_BLOCKLIST" 2> /dev/null \
        | head -n1 || true)

    if [ ! -s "$FLATPAK_BLOCKLIST" ]; then
        echo "FAIL: $FLATPAK_BLOCKLIST missing or empty"
    elif [ -z "$not_a_rule" ]; then
        echo "OK: every line of $FLATPAK_BLOCKLIST is an allow/deny rule"
    else
        echo "FAIL: $FLATPAK_BLOCKLIST has a line that is not a rule: $not_a_rule"
    fi
}

# The base's own file is the record: the RPM's copy must equal it.
check_firefox_defaults() {
    local source=/usr/share/ublue-os/firefox-config/01-bazzite-global.js
    local copy=/usr/lib64/firefox/browser/defaults/preferences/01-bazzite-global.js

    if [ -f "$source" ] && cmp -s "$source" "$copy"; then
        echo "OK: the Firefox RPM reads Bazzite's defaults"
    else
        echo "FAIL: $copy missing or not Bazzite's $source"
    fi
}

# --- 1Password ----------------------------------------------------------------

# The shipped key is the pinned one, the .repo is the vendored copy still
# disabled (the package's %post rewrites it, the build undoes that), and
# dnf5 imported the key into the rpm keyring at install.
check_onepassword_repo() {
    local repo_lines

    check_key_fingerprint "$KEY"

    if grep -qx 'enabled=0' "$ONEPASSWORD_REPO" 2> /dev/null; then
        echo "OK: $ONEPASSWORD_REPO disabled (the %post's rewrite was undone)"
    else
        repo_lines=$(grep -E '^(enabled|gpgkey)=' "$ONEPASSWORD_REPO" 2>&1 \
            | tr '\n' ' ' || true)
        echo "FAIL: $ONEPASSWORD_REPO: ${repo_lines:-no enabled or gpgkey line}"
    fi

    check_rpm_key 2012ea22 "1Password"
}

# The %post renders the owner list from /etc/passwd, so an empty one is the
# right state in an image (docs/divergences.md).
check_polkit_policy() {
    local action missing=() empty_owners named_users

    if [ -f "$POLICY" ] && xmllint --noout "$POLICY" 2> /dev/null; then
        echo "OK: $POLICY well-formed"
    else
        echo "FAIL: $POLICY missing or malformed"
    fi

    for action in unlock authorizeCLI authorizeSshAgent; do
        if ! grep -q "action id=\"com.1password.1Password.$action\"" "$POLICY" 2> /dev/null; then
            missing+=("$action")
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        echo "OK: polkit actions unlock, authorizeCLI, authorizeSshAgent declared"
    else
        echo "FAIL: polkit actions missing: ${missing[*]}"
    fi

    if [ ! -s "$POLICY" ]; then
        echo "FAIL: $POLICY missing or empty: no owner annotation read"
    elif ! grep -q 'unix-user:' "$POLICY" 2> /dev/null; then
        empty_owners=$(grep -c 'policykit.owner' "$POLICY" 2> /dev/null || true)
        echo "OK: no build-time user rendered as policy owner" \
            "($empty_owners empty owner annotation(s))"
    else
        named_users=$(grep -o 'unix-user:[^ <]*' "$POLICY" 2> /dev/null | tr '\n' ' ' || true)
        echo "FAIL: $POLICY names a build-time user: $named_users"
    fi
}

# The gids are fixed and above 1000 because the application rejects a lower
# one (docs/gotchas.md § The 1Password app rejects a BrowserSupport whose group
# id is below 1000); tests/80-fix-opt.sh ties the setgid binaries to them.
check_groups() {
    local spec group wanted_gid gid in_usr in_etc

    for spec in onepassword=31001 onepassword-mcp=31002; do
        group=${spec%%=*}
        wanted_gid=${spec#*=}
        gid=$(awk -F: -v g="$group" '$1 == g { print $3 }' /usr/lib/group 2> /dev/null || true)

        if [ "$gid" = "$wanted_gid" ] && ! grep -q "^${group}:" /etc/group 2> /dev/null; then
            echo "OK: group $group gid $gid in /usr/lib/group, not in /etc/group"
        else
            in_usr=$(grep "^${group}:" /usr/lib/group 2> /dev/null || true)
            in_etc=$(grep "^${group}:" /etc/group 2> /dev/null || true)
            echo "FAIL: group $group: /usr/lib/group=${in_usr:-none} /etc/group=${in_etc:-none}" \
                "(want $wanted_gid, relocated)"
        fi
    done
}

check_opt_links() {
    local link target

    for link in 1password 1password-mcp; do
        target=$(readlink "/usr/bin/$link" 2> /dev/null || true)

        if [ "$target" = "/opt/1Password/$link" ]; then
            echo "OK: /usr/bin/$link -> $target"
        else
            echo "FAIL: /usr/bin/$link -> '$target'"
        fi
    done

    if [ -f "$ALLOWED_BROWSERS" ]; then
        echo "OK: $ALLOWED_BROWSERS installed by the %post"
    else
        echo "FAIL: $ALLOWED_BROWSERS missing"
    fi
}

# --- main ---------------------------------------------------------------------

check_applications
check_flatpak_blocklist
check_firefox_defaults
check_onepassword_repo
check_polkit_policy
check_groups
check_opt_links
