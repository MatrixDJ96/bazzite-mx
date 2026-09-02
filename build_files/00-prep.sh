#!/usr/bin/env bash
# Prepare the build: dnf keeps its cache across builds, and the base image's
# repository files, enabled repositories and recipe sets are recorded, so the
# gates that run later can tell what the build changed.
#
# Usage: run by build.sh as the first script; no arguments.
# Writes: $BUILD_TMP/dnf.conf.base, restored by 95-clean-stage.sh;
#   $BUILD_STATE/repos.base.sha256 and repos.base.enabled, read by
#   90-validate-repos.sh; $BUILD_STATE/just.base.summary, read by
#   70-justfile.sh.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

JUST_DIR=/usr/share/ublue-os/just

# --- the steps ----------------------------------------------------------------

# The backup is put back by 95-clean-stage.sh with a rename, so the file the
# image ships sits on a fresh inode.
keep_dnf_cache() {
    cp /etc/dnf/dnf.conf "$BUILD_TMP/dnf.conf.base"
    dnf5 config-manager setopt keepcache=1 timeout=60

    if ! grep -q '^keepcache=1' /etc/dnf/dnf.conf; then
        fail_build "dnf.conf: keepcache=1 not applied"
    fi
}

# By content: 90-validate-repos.sh refuses a base file the build modified and
# treats a file outside this list as an addition.
record_base_repo_files() {
    local snapshot=$BUILD_STATE/repos.base.sha256

    (cd /etc/yum.repos.d && sha256sum -- *.repo) > "$snapshot"

    if [ ! -s "$snapshot" ]; then
        fail_build "no .repo files in the base image"
    fi

    log "prep: $(wc -l < "$snapshot") base repo files recorded"
}

# By dnf5's own answer: 90-validate-repos.sh requires the same set at the end,
# so an override file that enables a repository is caught as well.
record_base_enabled_repos() {
    local snapshot=$BUILD_STATE/repos.base.enabled

    enabled_repos > "$snapshot"

    if [ ! -s "$snapshot" ]; then
        fail_build "dnf5 reports no enabled repository in the base image"
    fi

    log "prep: enabled in the base: $(paste -sd ' ' "$snapshot")"
}

# One line per base .just file, `<file>: <recipe> <recipe> …`, a file without
# recipes recording an empty set. 70-justfile.sh refuses to replace a base
# file whose set drifted from ours, so a recipe upstream added cannot vanish.
# A file just cannot parse fails the build here, not at that guard.
record_base_recipe_sets() {
    local snapshot=$BUILD_STATE/just.base.summary
    local justfile names

    : > "$snapshot"

    for justfile in "$JUST_DIR"/*.just; do
        if ! names=$(recipe_set "$justfile"); then
            fail_build "just cannot parse the base's $justfile"
        fi

        names=$(tr '\n' ' ' <<< "$names")
        printf '%s: %s\n' "$(basename "$justfile")" "${names% }" >> "$snapshot"
    done

    if [ ! -s "$snapshot" ]; then
        fail_build "no .just files under $JUST_DIR in the base image"
    fi

    log "prep: $(wc -l < "$snapshot") base recipe files recorded"
}

# --- main ---------------------------------------------------------------------

keep_dnf_cache
record_base_repo_files
record_base_enabled_repos
record_base_recipe_sets
