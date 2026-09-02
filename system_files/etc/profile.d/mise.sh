# shellcheck shell=bash
# mise activation for every bash that sources profile.d, login or not:
# Fedora reaches the non-login ones through /etc/bashrc
# (mise.jdx.dev/installing-mise). Sourced by bash at shell start, never run;
# sh-compatible, so the other shells that read profile.d parse it and skip
# it. zsh and fish activate mise themselves.
#
# The guard on the binary keeps a shell clean if mise is ever removed.
if [ -n "${BASH_VERSION:-}" ] && [ -x /usr/bin/mise ]; then
    eval "$(/usr/bin/mise activate bash)"
fi
