#!/usr/bin/bash
# MX block 40: Dev / sysadmin CLI tools.
# Observability stack (BPF + profiling + I/O + network monitoring),
# Android debug bridge, NUMA tooling, Ftrace front-end, build/packaging
# (flatpak-builder), and fast recursive search (ripgrep).
#
# Note: cosign is already shipped by Bazzite base (cosign-3.0.6); we
# reuse it as-is for image verification. claude-code is NOT installed
# at build time — installing it would require pulling nodejs22 + npm
# + per-build npm globals (~55 MiB), and the user opted out for now.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

### Section 1: Observability + dev tooling (Fedora) ###
# Union of Aurora-DX and Bazzite-DX dev CLI lists, minus kcli (Aurora
# COPR, deferred until concrete need emerges). flatpak-builder is the
# packaging tool relocated from Phase 4 ("IDE") where it was an ill-fit.
#
# Note on bcc vs bcc-tools: both Aurora-DX and Bazzite-DX install only
# `bcc` (the library + Python bindings). The actual command-line
# utilities (`execsnoop`, `opensnoop`, `tcpconnect`, `runqlat`, ...)
# live in `bcc-tools`, a separate ~2 MiB package. We install both so
# users get the tools out of the box — small win over upstream.
dnf5 -y install \
    android-tools \
    bcc \
    bcc-tools \
    bpftrace \
    bpftop \
    sysprof \
    iotop \
    nicstat \
    numactl \
    trace-cmd \
    flatpak-builder \
    ripgrep

echo "::endgroup::"
