# shellcheck shell=bash
# mise activation for every bash that sources profile.d, login or not:
# Fedora reaches the non-login ones through /etc/bashrc
# (mise.jdx.dev/installing-mise). Sourced by bash at shell start, never run;
# sh-compatible, so the other shells that read profile.d parse it and skip
# it. Only bash gets mise activated: a fish account adds
# `if type -q mise; mise activate fish | source; end` to
# ~/.config/fish/config.fish.
if [ -n "${BASH_VERSION:-}" ]; then
    eval "$(/usr/bin/mise activate bash)"
fi
