#!/usr/bin/env bash
# Firefox, gparted and 1Password: the Flatpak filter, the vendored repository
# and key, the polkit actions, the relocated groups and the /opt symlinks.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
# shellcheck source=../lib/gpg.sh
source "$CTX/build_files/lib/gpg.sh"

check_pkg firefox firefox-langpacks gparted 1password

for app in org.mozilla.firefox gparted 1password; do
    check_desktop_file "/usr/share/applications/$app.desktop"
done
[ -x /usr/bin/firefox ] && echo "OK: /usr/bin/firefox executable" || echo "FAIL: /usr/bin/firefox missing"

# Our deny line once, the base's lines still there.
BLOCKLIST=/usr/share/ublue-os/flatpak-blocklist
check_flatpak_deny 'org.mozilla.firefox/*'
if [ "$(tail -n1 "$BLOCKLIST" 2>&1)" = 'deny org.mozilla.firefox/*' ]; then
    echo "OK: $BLOCKLIST: the Firefox deny line is last"
else
    echo "FAIL: $BLOCKLIST last line: $(tail -n1 "$BLOCKLIST" 2>&1)"
fi
if grep -q '^deny com.valvesoftware.Steam/\*$' "$BLOCKLIST" && [ "$(grep -c '^deny ' "$BLOCKLIST")" -ge 3 ]; then
    echo "OK: $BLOCKLIST keeps the base's deny lines"
else
    echo "FAIL: $BLOCKLIST lost the base's lines: $(tr '\n' ';' < "$BLOCKLIST")"
fi
bad=$(grep -vE '^(#|$|(allow|deny) [^ ]+$)' "$BLOCKLIST" | head -n1 || true)
if [ -z "$bad" ]; then
    echo "OK: every line of $BLOCKLIST is an allow/deny rule"
else
    echo "FAIL: $BLOCKLIST has a line that is not a rule: $bad"
fi

KEY=/etc/pki/rpm-gpg/RPM-GPG-KEY-1password
FPR=${KEY_FPR[$KEY]}
REPO=/etc/yum.repos.d/1password.repo
if [ "$(key_fingerprint "$KEY")" = "$FPR" ]; then
    echo "OK: $KEY fingerprint $FPR"
else
    echo "FAIL: $KEY fingerprint $(key_fingerprint "$KEY" || true)"
fi
if cmp -s "$CTX/system_files/etc/yum.repos.d/1password.repo" "$REPO" && grep -qx 'enabled=0' "$REPO"; then
    echo "OK: $REPO is the vendored copy, disabled (the %post's rewrite was undone)"
else
    echo "FAIL: $REPO: $(grep -E '^(enabled|gpgkey)=' "$REPO" 2>&1 | tr '\n' ' ')"
fi
if rpm -q gpg-pubkey --qf '%{VERSION}\n' | grep -qi '2012ea22$'; then
    echo "OK: 1Password key in the rpm keyring"
else
    echo "FAIL: 1Password key (…2012ea22) not in the rpm keyring"
fi

# The %post renders the owner list from /etc/passwd, so an empty one is the
# right state in an image (docs/divergences.md).
POLICY=/usr/share/polkit-1/actions/com.1password.1Password.policy
if [ -f "$POLICY" ] && xmllint --noout "$POLICY" 2> /dev/null; then
    echo "OK: $POLICY well-formed"
else
    echo "FAIL: $POLICY missing or malformed"
fi
missing=()
for action in unlock authorizeCLI authorizeSshAgent; do
    grep -q "action id=\"com.1password.1Password.$action\"" "$POLICY" 2> /dev/null || missing+=("$action")
done
if [ ${#missing[@]} -eq 0 ]; then
    echo "OK: polkit actions unlock, authorizeCLI, authorizeSshAgent declared"
else
    echo "FAIL: polkit actions missing: ${missing[*]}"
fi
if ! grep -q 'unix-user:' "$POLICY" 2> /dev/null; then
    echo "OK: no build-time user rendered as policy owner ($(grep -c 'policykit.owner' "$POLICY" 2> /dev/null || echo 0) empty owner annotation(s))"
else
    echo "FAIL: $POLICY names a build-time user: $(grep -o 'unix-user:[^ <]*' "$POLICY" | tr '\n' ' ')"
fi

# The gids are fixed and above 1000 because the application rejects a lower
# one (docs/gotchas.md); tests/80-fix-opt.sh ties the setgid binaries to them.
for spec in onepassword=31001 onepassword-mcp=31002; do
    g=${spec%%=*}
    want=${spec#*=}
    gid=$(awk -F: -v g="$g" '$1 == g { print $3 }' /usr/lib/group)
    if [ "$gid" = "$want" ] && ! grep -q "^${g}:" /etc/group; then
        echo "OK: group $g gid $gid in /usr/lib/group, not in /etc/group"
    else
        echo "FAIL: group $g: /usr/lib/group=$(grep "^${g}:" /usr/lib/group || echo none) /etc/group=$(grep "^${g}:" /etc/group || echo none) (want $want, relocated)"
    fi
done

for link in 1password 1password-mcp; do
    target=$(readlink "/usr/bin/$link" 2> /dev/null || true)
    if [ "$target" = "/opt/1Password/$link" ]; then
        echo "OK: /usr/bin/$link -> $target"
    else
        echo "FAIL: /usr/bin/$link -> '$target'"
    fi
done
if [ -f /etc/1password/custom_allowed_browsers ]; then
    echo "OK: /etc/1password/custom_allowed_browsers installed by the %post"
else
    echo "FAIL: /etc/1password/custom_allowed_browsers missing"
fi
