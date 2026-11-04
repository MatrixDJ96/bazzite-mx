#!/usr/bin/env bash
# The files the build adds outside an RPM get a chunkah component: the
# `user.component` and `user.update-interval` xattrs. A package scriptlet's
# output and the symlinks, on which the kernel refuses a user xattr, stay
# unclaimed (a row skips the links it matches, as Bazzite's assign_chunk), and a
# base file the build rewrites keeps the base's tag or none (`image-info.json`
# and the two .just files we replace aside), as in Bazzite.
#
# Usage: 85-chunk-components.sh              run by build.sh, no arguments
#        85-chunk-components.sh --self-test  the assignment on fixture trees,
#                                            `self-test ok: …` when the good
#                                            tree is tagged, its link skipped,
#                                            and the bad one refused
# Writes: the two xattrs on every path the COMPONENTS table matches.
# Exit status: 0 done; the build stops on a `FAIL: …` line, printed for a
#   pattern that matches nothing or an xattr not written.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

FIREFOX_PREFS=/usr/lib64/firefox/browser/defaults/preferences
PLASMA_UPDATES=/usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates

# <component> <update-interval> <pattern>, one pattern per row. The interval
# is chunkah's label; a component keeps one interval across its rows. A path a
# package owns stays out: its xattr would win over the rpmdb.
COMPONENTS=(
    "bazzite-mx-init monthly /usr/libexec/bazzite-mx-*"
    "bazzite-mx-init monthly /usr/libexec/bazzite-dx-kvmfr-setup"
    "bazzite-mx-init monthly /usr/lib/bazzite-mx/host.sh"
    "bazzite-mx-init monthly /usr/share/ublue-os/system-setup.hooks.d/*-bazzite-mx-*.sh"
    "bazzite-mx-init monthly /usr/share/ublue-os/user-setup.hooks.d/*-bazzite-mx-*.sh"
    "bazzite-mx-init monthly /usr/lib/systemd/system/docker.service.d/bazzite-mx-*.conf"
    "bazzite-mx-just monthly /usr/share/ublue-os/just/82-bazzite-sunshine.just"
    "bazzite-mx-just monthly /usr/share/ublue-os/just/84-bazzite-virt.just"
    "bazzite-mx-just monthly /usr/share/ublue-os/just/95-bazzite-mx.just"
    "bazzite-mx-system-config quarterly /etc/containers/registries.d/matrixdj96.yaml"
    "bazzite-mx-system-config quarterly /etc/pki/containers/matrixdj96.pub"
    "bazzite-mx-system-config quarterly /etc/pki/rpm-gpg/RPM-GPG-KEY-1password"
    "bazzite-mx-system-config quarterly /etc/pki/rpm-gpg/RPM-GPG-KEY-copr-jdxcode-mise"
    "bazzite-mx-system-config quarterly /etc/pki/rpm-gpg/RPM-GPG-KEY-copr-lizardbyte-stable"
    "bazzite-mx-system-config quarterly /etc/pki/rpm-gpg/RPM-GPG-KEY-docker-ce"
    "bazzite-mx-system-config quarterly /etc/pki/rpm-gpg/RPM-GPG-KEY-microsoft"
    "bazzite-mx-system-config quarterly /etc/profile.d/mise.sh"
    "bazzite-mx-system-config quarterly /etc/udisks2/mount_options.conf"
    "bazzite-mx-system-config quarterly /etc/yum.repos.d/1password.repo"
    "bazzite-mx-system-config quarterly /etc/yum.repos.d/docker-ce.repo"
    "bazzite-mx-system-config quarterly /etc/yum.repos.d/mise.repo"
    "bazzite-mx-system-config quarterly /etc/yum.repos.d/sunshine.repo"
    "bazzite-mx-system-config quarterly /etc/yum.repos.d/vscode.repo"
    "bazzite-mx-system-config quarterly /usr/lib/modprobe.d/bazzite-mx-*.conf"
    "bazzite-mx-system-config quarterly /usr/lib/modules-load.d/ip_tables.conf"
    "bazzite-mx-system-config quarterly /usr/lib/sysusers.d/bazzite-mx-groups.conf"
    "bazzite-mx-system-config quarterly /usr/lib/tmpfiles.d/bazzite-mx-*.conf"
    "bazzite-mx-desktop-config quarterly /etc/skel/.config/Code/User/settings.json"
    "bazzite-mx-desktop-config quarterly /etc/skel/.config/mise/config.toml"
    "bazzite-mx-desktop-config quarterly /etc/skel/.config/powershell/profile.ps1"
    "bazzite-mx-desktop-config quarterly /etc/skel/.local/share/kxmlgui5/konsole/sessionui.rc"
    "bazzite-mx-desktop-config quarterly $FIREFOX_PREFS/01-bazzite-global.js"
    "bazzite-mx-desktop-config quarterly $PLASMA_UPDATES/bazzite-mx-*.js"
    "bazzite-mx-kmods weekly /usr/lib/modules/*/updates/*.ko"
    "bazzite-mx-shfmt monthly /usr/bin/shfmt"
    "bazzite-mx-1password quarterly /usr/lib/opt/1Password"
    "bazzite-mx-build-info weekly /usr/share/ublue-os/image-info.json"
    "bazzite-mx-build-info weekly /usr/lib/bazzite-mx/build-state"
)

# --- the assignment -----------------------------------------------------------

# Prints `<component> <interval> <path>` for every path under <root> a row of
# COMPONENTS matches, a symlink aside (its xattr would land on the target), and
# a `FAIL: …` line for a row matching nothing. Status 1 on a FAIL.
resolve_components() {
    local root=$1
    local row component interval pattern path matches failed=0

    for row in "${COMPONENTS[@]}"; do
        read -r component interval pattern <<< "$row"
        matches=$(compgen -G "$root$pattern" || true)

        if [ -z "$matches" ]; then
            echo "FAIL: $pattern matches nothing (renamed or no longer written?)"
            failed=1
            continue
        fi

        while IFS= read -r path; do
            if [ ! -L "$path" ]; then
                echo "$component $interval $path"
            fi
        done <<< "$matches"
    done

    return "$failed"
}

# Tags every path the table matches under <root>; every row is resolved first,
# so one run reports every bad row. Prints one line per component.
assign_components() {
    local root=$1
    local resolved component interval path

    if ! resolved=$(resolve_components "$root"); then
        grep '^FAIL: ' <<< "$resolved"
        return 1
    fi

    while read -r component interval path; do
        if ! setfattr -n user.component -v "$component" "$path" \
            || ! setfattr -n user.update-interval -v "$interval" "$path"; then
            echo "FAIL: cannot tag $path"
            return 1
        fi
    done <<< "$resolved"

    awk '{ count[$1]++ } END { for (c in count) print c ": " count[c] " path(s)" }' \
        <<< "$resolved" | sort
}

# --- the self-test ------------------------------------------------------------

# Writes under <dir> a file at every path the table names, the patterns'
# wildcards read as one literal name, the kernel directory included.
self_test_tree() {
    local dir=$1
    local row pattern path

    for row in "${COMPONENTS[@]}"; do
        read -r _ _ pattern <<< "$row"
        path=$dir${pattern//\*/x}
        mkdir -p "$(dirname "$path")"
        : > "$path"
    done
}

# <path> under <dir> carries <component> and <interval>.
self_test_expect_tag() {
    local dir=$1
    local path=$2
    local component=$3
    local interval=$4
    local name found=""

    for name in user.component user.update-interval; do
        found+=" $(getfattr --absolute-names --only-values -n "$name" "$dir$path" 2>&1 || true)"
    done

    found=${found# }

    if [ "$found" != "$component $interval" ]; then
        fail_build "self-test: $path tagged '$found', expected '$component $interval'"
    fi
}

self_test_good_tree() {
    local dir=$1

    self_test_tree "$dir"
    : > "$dir/usr/bin/untagged"
    ln -s ../../usr/bin/untagged "$dir/usr/libexec/bazzite-mx-link"

    if ! assign_components "$dir" > "$dir.out" 2>&1; then
        fail_build "self-test: the known-good tree fails: $(cat "$dir.out")"
    fi

    self_test_expect_tag "$dir" /usr/libexec/bazzite-mx-x bazzite-mx-init monthly
    self_test_expect_tag "$dir" /usr/lib/modules/x/updates/x.ko bazzite-mx-kmods weekly
    self_test_expect_tag "$dir" /usr/share/ublue-os/image-info.json bazzite-mx-build-info weekly

    if getfattr -n user.component "$dir/usr/bin/untagged" > /dev/null 2>&1; then
        fail_build "self-test: a symlink's target tagged"
    fi

    echo "self-test: known-good tree tagged, its symlink skipped"
}

# Known-bad: a row whose path is gone.
self_test_bad_tree() {
    local dir=$1/missing
    local message="FAIL: /usr/lib/sysusers.d/bazzite-mx-groups.conf matches nothing"

    self_test_tree "$dir"
    rm "$dir/usr/lib/sysusers.d/bazzite-mx-groups.conf"

    if assign_components "$dir" > "$dir.out" 2>&1; then
        fail_build "self-test: a listed path gone passed"
    fi

    if ! grep -qF "$message" "$dir.out"; then
        fail_build "self-test: a listed path gone failed for another reason: $(cat "$dir.out")"
    fi

    echo "self-test: caught a listed path gone"
}

self_test() {
    local dir

    dir=$(mktemp -d)
    # shellcheck disable=SC2064  # expand now: the local is gone at EXIT
    trap "rm -rf '$dir'" EXIT

    self_test_good_tree "$dir/good"
    self_test_bad_tree "$dir"

    echo "self-test ok: 1 good tree tagged, its symlink skipped, 1 bad tree refused"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    "")
        if ! assign_components ""; then
            fail_build "chunk-components: COMPONENTS not applied"
        fi

        log "chunk-components: ${#COMPONENTS[@]} rows tagged"
        ;;
    *)
        fail_build "usage: 85-chunk-components.sh [--self-test]"
        ;;
esac
