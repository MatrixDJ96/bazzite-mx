#!/usr/bin/env bash
# What the verify-host, migrate and ntfsplus-setup helpers read about the
# host, and the error and privilege helpers they share. Sourced by them,
# never run; the sourcing script sets its own `set` options.
#
# FIXTURE=<dir>: every file is read under <dir> and every command's output
# under <dir>/cmd/, so a helper runs on a synthetic host in the smoke tests.
# Output contract: `ERROR: <reason>` on stderr is what the recipes and the
# tests read.

FIXTURE=${FIXTURE:-}
VENDOR_SCOPE=ghcr.io/matrixdj96
IMAGE_INFO=/usr/share/ublue-os/image-info.json

# Written by bazzite-mx-ntfsplus-setup enable: a comments-only file masking
# the image's blacklist of the same name.
NTFSPLUS_OPTIN=/etc/modprobe.d/bazzite-mx-ntfsplus.conf

# Written by bazzite-mx-msi-setup enable.
MSI_MODULES_LOAD=/etc/modules-load.d/bazzite-mx-msi.conf

# --- errors and privileges ----------------------------------------------------

print_error() {
    echo "ERROR: $*" >&2
}

# Only a command calls it: a function a command runs under `if` returns a
# status, because an exit there would end the script without its message.
exit_with_error() {
    print_error "$@"
    exit 1
}

# require_root <action> <recipe>: the recipe runs the action through sudo.
require_root() {
    local action=$1
    local recipe=$2

    if [ "$(id -u)" -ne 0 ]; then
        exit_with_error "$action needs root (ujust $recipe runs it through sudo)"
    fi
}

# --- the host's files and commands --------------------------------------------

# host_file <path>: the path to read, under the fixture when there is one.
host_file() {
    local path=$1

    echo "$FIXTURE$path"
}

# The fixture replaces a command with its recorded output.
src_rpm_ostree_status() {
    if [ -n "$FIXTURE" ]; then
        cat "$FIXTURE/cmd/rpm-ostree-status.json"
    else
        rpm-ostree status --json
    fi
}

src_kargs() {
    if [ -n "$FIXTURE" ]; then
        cat "$FIXTURE/cmd/kargs"
    else
        rpm-ostree kargs
    fi
}

# --- the image and its origin -------------------------------------------------

# image_name: empty when image-info.json is unreadable.
image_name() {
    jq -r '."image-name" // ""' "$(host_file $IMAGE_INFO)" 2> /dev/null || true
}

# booted_deployment <status-json>: empty when no deployment is booted.
booted_deployment() {
    local status_json=$1

    jq '.deployments[] | select(.booted == true)' <<< "$status_json"
}

# layered_requests <deployment-json>: every request the origin still carries,
# space-separated. A request the image already satisfies leaves `packages`
# empty and stays in requested-packages, where bootc still counts it
# (docs/gotchas.md § rpm-ostree keeps a satisfied request in the origin).
layered_requests() {
    local deployment_json=$1
    local request_lists='[(.packages // []), (."requested-packages" // []),
        (."requested-local-packages" // []), (."requested-local-fileoverride-packages" // []),
        (."requested-base-local-replacements" // []), (."requested-base-removals" // []),
        (."requested-modules" // [])]'

    jq -r "$request_lists | flatten | unique | join(\" \")" <<< "$deployment_json"
}

# policy_scope_type: sigstoreSigned on this image, empty when the scope is
# absent.
policy_scope_type() {
    local policy

    policy=$(host_file /etc/containers/policy.json)
    jq -r --arg s "$VENDOR_SCOPE" '.transports.docker[$s][0].type // ""' "$policy" \
        2> /dev/null || true
}

# --- fstab and NTFS -----------------------------------------------------------

# fstab_entries <fstab>: the rows, comments and blank lines dropped.
fstab_entries() {
    local fstab=$1

    grep -vE '^\s*(#|$)' "$fstab" 2> /dev/null || true
}

ntfsplus_optin() {
    [ -e "$(host_file $NTFSPLUS_OPTIN)" ]
}

ntfs_registered() {
    grep -qw ntfs "$(host_file /proc/filesystems)" 2> /dev/null
}

# The text of the opt-in file. The fixtures write the same, so what keeps it
# out of the residue is the exclusion by name in ntfsplus_files, not a text
# the grep happens to miss.
ntfsplus_optin_text() {
    printf '# bazzite-mx: NTFSPLUS opt-in of this host. A file of this name in /etc/modprobe.d\n'
    printf '# masks /usr/lib/modprobe.d/bazzite-mx-ntfsplus.conf (blacklist ntfs). Written by\n'
    printf '# ujust setup-ntfsplus enable, removed by disable.\n'
}

# --- residue ------------------------------------------------------------------

# Residue of a host that loaded ntfsplus on its own, one path per line. The
# opt-in file carries the same name and is not residue.
ntfsplus_files() {
    grep -rls ntfsplus "$(host_file /etc/modprobe.d)" "$(host_file /etc/modules-load.d)" \
        2> /dev/null \
        | sed "s|^$FIXTURE||" \
        | grep -vx "$NTFSPLUS_OPTIN" || true
}

ntfsplus_kargs() {
    src_kargs | tr ' ' '\n' | grep ntfsplus || true
}

# Residue of a host that loaded the MSI modules on its own: the file
# setup-msi writes is not residue.
msi_files() {
    grep -rlsE 'msi[-_]ec|acpi_ec' "$(host_file /etc/modules-load.d)" 2> /dev/null \
        | sed "s|^$FIXTURE||" \
        | grep -vx "$MSI_MODULES_LOAD" || true
}
