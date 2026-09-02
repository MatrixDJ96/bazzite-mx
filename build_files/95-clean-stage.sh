#!/usr/bin/env bash
# Leave the tree in the state bootc lint and the rechunk expect. Two things
# stay on purpose: the kernel versionlock, which holds a host on the ogc
# kernel, and flatpak-add-fedora-repos.service, which puts Flathub on a host.
#
# Usage: run by build.sh as the last script; no arguments.
# Writes: /etc/dnf/dnf.conf restored from 00-prep.sh's backup; the accounts
#   package %post scripts created moved from /etc to /usr/lib; the rpmdb
#   hardlinked for rpm-ostree; /var, /run, /tmp and /boot emptied.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

BASE_DB=/usr/lib/sysimage/rpm-ostree-base-db

# --- the steps ----------------------------------------------------------------

# The backup goes back with a rename, so the file sits on a fresh inode.
restore_dnf_conf() {
    mv -f "$BUILD_TMP/dnf.conf.base" /etc/dnf/dnf.conf

    if ! grep -q '^keepcache=0' /etc/dnf/dnf.conf; then
        fail_build "dnf.conf not restored"
    fi

    rm -rf /usr/lib/sysimage/libdnf5/*
}

# Appends <lines> to <lib-file>, on a fresh inode, and proves each landed.
append_to_lib_file() {
    local lib_file=$1
    local lines=$2
    local line

    {
        cat "$lib_file" 2> /dev/null || true
        echo "$lines"
    } > "$lib_file.new"
    mv -f "$lib_file.new" "$lib_file"

    while IFS= read -r line; do
        if ! grep -qxF -- "$line" "$lib_file"; then
            fail_build "'$line' did not persist in $lib_file"
        fi
    done <<< "$lines"
}

# Drops the shadow entry of every account named in <lines>.
drop_shadow_entries() {
    local shadow_file=$1
    local lines=$2
    local line name

    if [ ! -f "$shadow_file" ]; then
        return 0
    fi

    while IFS= read -r line; do
        name=${line%%:*}
        sed -i "/^${name}:/d" "$shadow_file"
    done <<< "$lines"
}

# Accounts created by package %post scripts move from <etc-file> to
# <lib-file>, where NSS reads them too, so a host's /etc merge never drops
# them. The lines matching <keep> stay and <etc-file> is reset to <reset>.
relocate_accounts() {
    local etc_file=$1
    local lib_file=$2
    local shadow_file=$3
    local keep=$4
    local reset=$5
    local moving

    if [ ! -f "$etc_file" ]; then
        return 0
    fi

    moving=$(grep -vE -- "$keep" "$etc_file") || true

    if [ -z "$moving" ]; then
        return 0
    fi

    log "moving from $etc_file to $lib_file:"
    echo "$moving"

    append_to_lib_file "$lib_file" "$moving"
    printf '%s\n' "$reset" > "$etc_file.new"
    mv -f "$etc_file.new" "$etc_file"
    drop_shadow_entries "$shadow_file" "$moving"
}

# The rpmdb rpm-ostree reads must be the one dnf5 wrote, and a hardlink
# rather than a symlink (github.com/coreos/rpm-ostree/issues/4554).
link_rpmdb() {
    local file

    for file in rpmdb.sqlite rpmdb.sqlite-shm rpmdb.sqlite-wal; do
        if [ -f "/usr/share/rpm/$file" ] && [ -f "$BASE_DB/$file" ]; then
            ln -f "/usr/share/rpm/$file" "$BASE_DB/$file"
        fi
    done
}

# Every build-time directory under /var goes: cache and log are the build's
# own mounts, which find cannot delete anyway. The /run entries buildah
# binds for the RUN (resolv.conf, secrets, .containerenv) are mounts too;
# they stay out of the image because the Containerfile makes /run a tmpfs.
empty_build_directories() {
    find /var/* -maxdepth 0 -type d ! -name cache ! -name log -exec rm -rf {} +

    find /run -mindepth 1 \
        ! -path '/run/systemd' \
        ! -path '/run/systemd/resolve' \
        ! -path '/run/systemd/resolve/stub-resolv.conf' \
        ! -path '/run/secrets' \
        ! -path '/run/secrets/*' \
        ! -path '/run/.containerenv' \
        -delete

    find /tmp /boot -mindepth 1 -delete
    mkdir -p /var/tmp
    chmod 1777 /var/tmp
}

# --- main ---------------------------------------------------------------------

restore_dnf_conf

relocate_accounts /etc/passwd /usr/lib/passwd /etc/shadow \
    '^root:' 'root:x:0:0:root:/root:/bin/bash'
relocate_accounts /etc/group /usr/lib/group /etc/gshadow \
    '^(root|wheel):' 'root:x:0:
wheel:x:10:'
rm -f /etc/.pwd.lock /etc/passwd- /etc/group- /etc/shadow- /etc/gshadow- /etc/subuid- /etc/subgid-

# The rpmdb rpm-ostree reads must be the one dnf5 wrote (hardlink, not
# symlink: aurora clean-stage.sh, rpm-ostree#4554).
for f in rpmdb.sqlite rpmdb.sqlite-shm rpmdb.sqlite-wal; do
    if [ -f "/usr/share/rpm/$f" ] && [ -f "/usr/lib/sysimage/rpm-ostree-base-db/$f" ]; then
        ln -f "/usr/share/rpm/$f" "/usr/lib/sysimage/rpm-ostree-base-db/$f"
    fi
done

# Nothing build-time survives under /var, /run, /tmp, /boot. /var/cache and
# /var/log are cache mounts during the build (Containerfile) and cannot be
# removed here (aurora clean-stage.sh: "things we can't delete here are mounts").
find /var/* -maxdepth 0 -type d ! -name cache ! -name log -exec rm -rf {} +
find /run -mindepth 1 \
    ! -path '/run/systemd' \
    ! -path '/run/systemd/resolve' \
    ! -path '/run/systemd/resolve/stub-resolv.conf' \
    ! -path '/run/secrets' \
    ! -path '/run/secrets/*' \
    ! -path '/run/.containerenv' \
    -delete
find /tmp /boot -mindepth 1 -delete
mkdir -p /var/tmp
chmod 1777 /var/tmp

log "clean-stage: tree ready for lint"
