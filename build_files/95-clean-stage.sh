#!/usr/bin/env bash
# Leave the tree in the state bootc lint and the rechunk expect. Two things
# stay on purpose: the kernel versionlock, which holds a host on the ogc
# kernel, and flatpak-add-fedora-repos.service, which puts Flathub on a host.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

mv -f "$BUILD_TMP/dnf.conf.base" /etc/dnf/dnf.conf
grep -q '^keepcache=0' /etc/dnf/dnf.conf || die "dnf.conf not restored"

rm -rf /usr/lib/sysimage/libdnf5/*

# Accounts created by package %post scripts move from /etc to /usr/lib, so a
# host's /etc merge never drops them.
relocate_accounts() {
    local etc=$1 lib=$2 shadow=$3 keep=$4 reset=$5
    local out line name
    [ -f "$etc" ] || return 0
    out=$(grep -vE -- "$keep" "$etc") || true
    [ -n "$out" ] || return 0
    log "moving from $etc to $lib:"
    echo "$out"
    {
        cat "$lib" 2> /dev/null || true
        echo "$out"
    } > "$lib.new"
    mv -f "$lib.new" "$lib"
    while IFS= read -r line; do
        grep -qxF -- "$line" "$lib" || die "'$line' did not persist in $lib"
    done <<< "$out"
    printf '%s\n' "$reset" > "$etc.new"
    mv -f "$etc.new" "$etc"
    if [ -f "$shadow" ]; then
        while IFS= read -r line; do
            name=${line%%:*}
            sed -i "/^${name}:/d" "$shadow"
        done <<< "$out"
    fi
}
relocate_accounts /etc/passwd /usr/lib/passwd /etc/shadow \
    '^root:' 'root:x:0:0:root:/root:/bin/bash'
relocate_accounts /etc/group /usr/lib/group /etc/gshadow \
    '^(root|wheel):' 'root:x:0:
wheel:x:10:'
rm -f /etc/.pwd.lock /etc/passwd- /etc/group- /etc/shadow- /etc/gshadow- /etc/subuid- /etc/subgid-

# The rpmdb rpm-ostree reads must be the one dnf5 wrote, and a hardlink
# rather than a symlink (github.com/coreos/rpm-ostree/issues/4554).
for f in rpmdb.sqlite rpmdb.sqlite-shm rpmdb.sqlite-wal; do
    if [ -f "/usr/share/rpm/$f" ] && [ -f "/usr/lib/sysimage/rpm-ostree-base-db/$f" ]; then
        ln -f "/usr/share/rpm/$f" "/usr/lib/sysimage/rpm-ostree-base-db/$f"
    fi
done

# Every build-time directory under /var goes. cache and log are the build's
# own mounts, which find cannot delete anyway.
find /var/* -maxdepth 0 -type d ! -name cache ! -name log -exec rm -rf {} +
# The /run entries buildah binds for the RUN (resolv.conf, secrets,
# .containerenv) are mounts too: they stay out of the image because the
# Containerfile makes /run a tmpfs.
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
