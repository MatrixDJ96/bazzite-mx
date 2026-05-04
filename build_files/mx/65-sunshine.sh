#!/usr/bin/bash
# MX block 65: Sunshine self-hosted game-streaming host (Moonlight server).
#
# Background: Bazzite shipped Sunshine as a system RPM from the
# `lizardbyte/beta` COPR until commit 079fa8ad (2026-03-26), when they
# removed it because LizardByte's stable repo had not been updated for
# Fedora 43 in ~6 months. Bazzite then migrated to a Homebrew-based
# `setup-sunshine` recipe (commit aa6ec9da) that depends on a
# user-installed brew formula at /home/linuxbrew/.linuxbrew/.
#
# Why we re-integrate as system RPM:
#  - LizardByte's beta COPR resumed Fedora 44 builds in 2026-04
#    (verified 2026-05-04: package Sunshine 2026.428.130031-1.fc44
#    available, building cleanly, post-install scriptlet rpm-ostree
#    aware). The "stable repo broken" reason no longer holds.
#  - Aurora upstream never abandoned this path
#    (`aurora/build_files/base/01-packages.sh:206-208`) and has been
#    running it continuously without issues — same COPR, same package,
#    same `--global disable` user-service convention.
#  - Brew on bazzite ostree adds a non-trivial first-run cost
#    (download + compile a 30+ MiB binary on each user's machine),
#    plus a homebrew installation prerequisite. RPM layering is one
#    `bootc upgrade` away with the right COPR enabled at build time.
#
# Pattern: same as `ublue-os-libvirt-workarounds` in 20-virtualization
# .sh — `copr_install_isolated` enables the COPR, installs the package,
# then disables the COPR. `validate-repos.sh` enforces enabled=0 at the
# end of the build, so a future bootc upgrade from the user's host
# never silently picks up unrelated updates from this COPR.
#
# DNF idiom note: the package name is `Sunshine` (capitalized) per the
# rpm metadata, but DNF resolves package names case-insensitively at
# install time; we use the lowercase form to match Aurora's exact
# pattern. `rpm -q` IS case-sensitive, so the smoke test queries
# `rpm -q Sunshine` (capitalized).

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

# shellcheck disable=SC1091
source /ctx/build_files/shared/copr-helpers.sh

### Section 1: install Sunshine from lizardbyte/beta (isolated COPR) ###
copr_install_isolated "lizardbyte/beta" "sunshine"

### Section 2: setcap for KMS capture (high-performance path) ###
# Sunshine's KMS-based capture (Wayland and X11) requires CAP_SYS_ADMIN
# at process startup to use `/dev/dri/card*` for direct framebuffer
# scrape. Without this capability, Sunshine falls back to a slower
# software-composited capture (PipeWire screencast portal), which
# adds ~5-15 ms latency depending on resolution and reduces frame
# pacing accuracy.
#
# The COPR package does NOT ship the setcap (verified 2026-05-04 via
# `getcap` after fresh install in a Bazzite container). Bazzite's
# pre-removal Containerfile applied it manually with the same line.
# `readlink -f` resolves the version-suffixed alternative (e.g.
# /usr/bin/sunshine-2026.428.130031) so the cap lands on the actual
# binary, not the symlink.
setcap 'cap_sys_admin+p' "$(readlink -f /usr/bin/sunshine)"

### Section 3: defense-in-depth: ensure user service stays disabled ###
# The COPR-shipped `app-dev.lizardbyte.app.Sunshine.service` does NOT
# ship a systemd-preset entry (verified 2026-05-04 in a Bazzite
# container: `systemctl --global is-enabled` returns `disabled` even
# without any explicit action). So the call below is a no-op on the
# current package version.
#
# We keep it for two reasons:
#  1. Defense-in-depth: if LizardByte ever adds a preset that enables
#     the unit by default, our build immediately overrides it. Aurora
#     uses the same line for the same reason
#     (aurora/build_files/base/17-cleanup.sh:32).
#  2. Self-documenting intent: a reader of the build log sees that
#     Sunshine is meant to be opt-in by the user, not auto-running
#     in every session.
#
# User opts in with:
#   systemctl --user enable --now app-dev.lizardbyte.app.Sunshine.service
# (or use the alias: `sunshine.service`). The `setup-sunshine` ujust
# recipe (override in system_files/.../just/82-bazzite-sunshine.just)
# wraps this in a friendly UI.
systemctl --global disable app-dev.lizardbyte.app.Sunshine.service

### Section 4: drop Bazzite's "switch-to-brew" announcement nag ###
# `/usr/share/ublue-os/announcements/sunshine-brew.msg.json` shows a
# big "Sunshine will soon be removed from the base Bazzite image, and
# you will need to reinstall it in Bazzite Portal." nag whenever the
# user has a sunshine config and is NOT using brew. With our RPM
# integration the nag is permanently misleading.
NAG=/usr/share/ublue-os/announcements/sunshine-brew.msg.json
[ -f "$NAG" ] && rm -f "$NAG"

echo "::endgroup::"
