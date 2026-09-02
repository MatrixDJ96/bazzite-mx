# shellcheck shell=bash
# mise activation for every bash that sources profile.d, login or not
# (mise.jdx.dev/installing-mise; Fedora reaches the non-login ones through
# /etc/bashrc). The guard keeps a shell clean if mise is ever removed, and
# zsh and fish activate mise themselves.
if [ -n "${BASH_VERSION:-}" ] && [ -x /usr/bin/mise ]; then
    eval "$(/usr/bin/mise activate bash)"
fi
