#!/usr/bin/env bash
# Nothing under /var/opt, every tmpfiles line applied on a fixture root, and
# 1Password's binaries with the modes and groups its %post set.
set -euo pipefail

FIX_OPT=$(dirname "$(realpath "$0")")/../80-fix-opt.sh
CONF=/usr/lib/tmpfiles.d/bazzite-mx-opt.conf

if bash "$FIX_OPT" --self-test > /dev/null; then
    echo "OK: fix-opt self-test refuses the known-bad layouts"
else
    echo "FAIL: fix-opt self-test"
fi

if [ -z "$(ls -A /var/opt 2> /dev/null)" ]; then
    echo "OK: /var/opt empty in the image"
else
    echo "FAIL: /var/opt holds $(ls -A /var/opt | tr '\n' ' ')"
fi

if [ -s "$CONF" ] && grep -q '^L+ /var/opt/1Password - - - - /usr/lib/opt/1Password$' "$CONF"; then
    echo "OK: $CONF links /var/opt/1Password to /usr/lib/opt/1Password"
else
    echo "FAIL: $CONF: $(cat "$CONF" 2>&1 | tr '\n' ';')"
fi
bad=$(grep -vE '^L\+ /var/opt/[^ /]+ - - - - /usr/lib/opt/[^ /]+$' "$CONF" | head -n1 || true)
if [ -z "$bad" ]; then
    echo "OK: every line of $CONF is an L+ rule"
else
    echo "FAIL: $CONF has a line that is not an L+ rule: $bad"
fi
n=0
while read -r _ link _ _ _ _ target; do
    if [ -d "$target" ] && [ "$(basename "$link")" = "$(basename "$target")" ]; then
        n=$((n + 1))
    else
        echo "FAIL: $CONF: $link -> $target, target missing or names differ"
    fi
done < "$CONF"
if [ "$n" -gt 0 ]; then
    echo "OK: $n tmpfiles target(s) exist under /usr/lib/opt"
else
    echo "FAIL: $CONF applies no tmpfiles rule"
fi

# systemd-tmpfiles creates the links a host gets at boot, so the file is
# proven to parse and to do what it says.
fx=$(mktemp -d)
mkdir -p "$fx/var/opt"
if systemd-tmpfiles --root="$fx" --create "$CONF" 2> "$fx/err" \
    && [ "$(readlink "$fx/var/opt/1Password")" = /usr/lib/opt/1Password ]; then
    echo "OK: systemd-tmpfiles applies $CONF on a fixture root"
else
    echo "FAIL: systemd-tmpfiles on a fixture root: $(cat "$fx/err") link=$(readlink "$fx/var/opt/1Password" 2>&1 || true)"
fi
rm -rf "$fx"

# What 1Password's %post sets: chrome-sandbox setuid root, the browser helper
# and the MCP server setgid to their groups, the gid read from /usr/lib/group.
OPT=/usr/lib/opt/1Password
if [ -x "$OPT/1password" ] && [ -f "$OPT/com.1password.1Password.policy.tpl" ]; then
    echo "OK: $OPT holds the application"
else
    echo "FAIL: $OPT incomplete: $(ls "$OPT" 2>&1 | head -n3 | tr '\n' ' ')"
fi
mode=$(stat -c '%a %u' "$OPT/chrome-sandbox" 2>&1 || true)
if [ "$mode" = "4755 0" ]; then
    echo "OK: chrome-sandbox 4755 root"
else
    echo "FAIL: chrome-sandbox: $mode"
fi
gid_of() { awk -F: -v g="$1" '$1 == g { print $3 }' /usr/lib/group; }
for pair in "1Password-BrowserSupport:onepassword" "1password-mcp:onepassword-mcp"; do
    bin=${pair%%:*}
    group=${pair##*:}
    gid=$(gid_of "$group")
    st=$(stat -c '%a %g' "$OPT/$bin" 2>&1 || true)
    if [ -n "$gid" ] && [ "$st" = "2755 $gid" ]; then
        echo "OK: $bin setgid $group ($gid)"
    else
        echo "FAIL: $bin: mode/gid '$st', group $group gid '${gid:-none}'"
    fi
done
if [ "$(readlink "$OPT/onepassword-mcp" 2> /dev/null || true)" = /opt/1Password/1password-mcp ]; then
    echo "OK: onepassword-mcp alias points through /opt"
else
    echo "FAIL: onepassword-mcp alias: $(readlink "$OPT/onepassword-mcp" 2>&1 || echo missing)"
fi
