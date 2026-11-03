#!/usr/bin/env bash
# KDE defaults: seconds on the panel clock, a panel on every screen, Windows
# style copy and paste in Konsole and PowerShell. They ship as Plasma update
# scripts, skel files and the user hook that seeds the skel files into the
# accounts that predate the image, all from system_files/; this script only
# logs the feature, tests/45-kde-defaults.sh proves they landed.
#
# Usage: run by build.sh; no arguments.
# Writes: nothing.
# Exit status: 0 done.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

plasma_version=$(rpm -q --qf '%{VERSION}' plasma-workspace)
log "kde-defaults: 2 update scripts, Konsole and PowerShell skel files, their user hook," \
    "setup-panels recipe (plasma-workspace $plasma_version)"
