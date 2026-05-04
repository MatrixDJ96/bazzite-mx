#!/usr/bin/bash
# MX block 47: install rpmfusion-nonfree-release to ship the GPG keys
# and .repo files for RPM Fusion non-free without static vendoring.
#
# Why this approach instead of vendoring the `.repo` and key under
# `system_files/`:
#  - GPG keys auto-update via standard `bootc upgrade` whenever RPM
#    Fusion publishes a new release-package version (rare rotation,
#    but when it happens we get it for free).
#  - Future-proof: the package already ships keys for Fedora 45/46
#    and rawhide. No maintenance debt at the next Bazzite rebase.
#  - Trust model: the package's key is signed by the Fedora master
#    key, already trusted by Bazzite (transitive trust via signed rpm).
#
# The `.repo` files arrive `enabled=1` from upstream (RPM Fusion's
# default). We disable them immediately to align with the project
# pattern (`enabled=0` baseline + targeted `--enablerepo=` at build
# time, or runtime-enabled via a ujust recipe for opt-in installs).

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

dnf5 -y install \
    "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"

# Disable every main section of the .repo files shipped by the package.
# The `g` flag is necessary because each file has 3 sections (main +
# debuginfo + source), with enabled=1 only on release/updates main and
# enabled=0 on debuginfo/source. The `g` flips only the mains (the
# others are already 0).
sed -i 's/^enabled=1/enabled=0/g' \
    /etc/yum.repos.d/rpmfusion-nonfree.repo \
    /etc/yum.repos.d/rpmfusion-nonfree-updates.repo \
    /etc/yum.repos.d/rpmfusion-nonfree-updates-testing.repo

echo "::endgroup::"
