# shellcheck shell=bash
# mise activation for every bash that sources profile.d,
# login or not (Fedora reaches non-login shells via /etc/bashrc). Kept sh-compatible:
# other shells that read profile.d parse it and skip the block.
if [ -n "${BASH_VERSION:-}" ]; then
    eval "$(/usr/bin/mise activate bash)"
fi
