#!/usr/bin/env bash
# Prepare the build: dnf keeps its cache across builds, its metadata refreshed
# once here, and fails on a repository it cannot reach unless the repository's
# own file says skip_if_unavailable=True; the base image's repository files,
# enabled repositories, recipe sets and module dependencies are recorded, so
# the gates that run later can tell what the build changed.
#
# Usage: run by build.sh as the first script; no arguments.
# Writes: $BUILD_TMP/dnf.conf.base, restored by 95-clean-stage.sh;
#   $BUILD_STATE/repos.base.sha256 and repos.base.enabled, read by
#   90-validate-repos.sh, the first also by bazzite-mx-verify-host on every
#   host; $BUILD_STATE/just.base.summary, read by 70-justfile.sh;
#   $BUILD_STATE/modules.base.dep.gz, read by tests/50-kmods.sh.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

JUST_DIR=/usr/share/ublue-os/just

# --- the steps ----------------------------------------------------------------

# The backup, its user xattrs (the base's chunkah component) with it, is put
# back by 95-clean-stage.sh with a rename, so the file the image ships sits on a
# fresh inode; --preserve=xattr fails, the RUN's tmpfs refusing security.selinux.
# timeout=60 rides out COPR and mirror flakes; the base's skip_if_unavailable=1
# would install without an unreachable repository.
set_build_dnf_options() {
    cp /etc/dnf/dnf.conf "$BUILD_TMP/dnf.conf.base"
    getfattr --absolute-names -d -m '^user\.' /etc/dnf/dnf.conf \
        | sed "s|^# file: .*|# file: $BUILD_TMP/dnf.conf.base|" \
        | setfattr -h -P --restore=-
    dnf5 config-manager setopt keepcache=1 timeout=60 skip_if_unavailable=False
}

# The cache outlives a build, so metadata it kept could predate the mirrors.
refresh_dnf_metadata() {
    dnf_retry makecache --refresh
}

# By content: 90-validate-repos.sh refuses a base file the build modified and
# treats a file outside this list as an addition.
record_base_repo_files() {
    local snapshot=$BUILD_STATE/repos.base.sha256

    (cd /etc/yum.repos.d && sha256sum -- *.repo) > "$snapshot"

    log "prep: $(wc -l < "$snapshot") base repo files recorded"
}

# By dnf5's own answer: 90-validate-repos.sh requires the same set at the end,
# so an override file that enables a repository is caught as well.
record_base_enabled_repos() {
    local snapshot=$BUILD_STATE/repos.base.enabled

    enabled_repos > "$snapshot"

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

    log "prep: $(wc -l < "$snapshot") base recipe files recorded"
}

# The base's own modules.dep, gzipped: 50-kmods.sh re-runs depmod over the
# whole tree, the base's modules with it, and tests/50-kmods.sh requires every
# recorded line back, so a base module ours displaced is caught.
record_base_module_deps() {
    local snapshot=$BUILD_STATE/modules.base.dep.gz
    local deps=(/usr/lib/modules/*/modules.dep)

    # -n: the base's normalised mtime does not fit gzip's header, and the
    # warning is exit 2, which set -e takes for a failure.
    gzip -nc "${deps[0]}" > "$snapshot"

    log "prep: $(wc -l < "${deps[0]}") base module dependency lines recorded"
}

# --- main ---------------------------------------------------------------------

set_build_dnf_options
refresh_dnf_metadata
record_base_repo_files
record_base_enabled_repos
record_base_recipe_sets
record_base_module_deps
