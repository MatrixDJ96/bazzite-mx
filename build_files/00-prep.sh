#!/usr/bin/env bash
# Prepare the build: dnf keeps its cache across builds, and the base image's
# repository and recipe sets are recorded so the later gates can tell what
# the build changed.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

# Backup restored by 95-clean-stage.sh (rename onto a fresh inode).
cp /etc/dnf/dnf.conf "$BUILD_TMP/dnf.conf.base"
dnf5 config-manager setopt keepcache=1 timeout=60
grep -q '^keepcache=1' /etc/dnf/dnf.conf || die "dnf.conf: keepcache=1 not applied"

# Snapshot of the base's .repo files, by content: the validator refuses a
# base file the build modified and treats anything else as an addition.
(cd /etc/yum.repos.d && sha256sum -- *.repo) > "$BUILD_STATE/repos.base.sha256"
[ -s "$BUILD_STATE/repos.base.sha256" ] || die "no .repo files in the base image"
log "prep: $(wc -l < "$BUILD_STATE/repos.base.sha256") base repo files recorded"
