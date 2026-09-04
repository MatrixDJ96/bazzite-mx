#!/usr/bin/env bash
# The host state the verify-host, migrate and ntfsplus-setup helpers read.
# Sourced by them, never run.
# FIXTURE=<dir>: files are read under <dir>, command outputs under <dir>/cmd/.

FIXTURE=${FIXTURE:-}
VENDOR_SCOPE=ghcr.io/matrixdj96
IMAGE_INFO=/usr/share/ublue-os/image-info.json
# Written by bazzite-mx-ntfsplus-setup enable: a comments-only file masking
# the image's blacklist of the same name.
NTFSPLUS_OPTIN=/etc/modprobe.d/bazzite-mx-ntfsplus.conf
# Written by bazzite-mx-msi-setup enable.
MSI_MODULES_LOAD=/etc/modules-load.d/bazzite-mx-msi.conf

f() { echo "$FIXTURE$1"; }

# The fixture replaces a command with its recorded output.
src_rpm_ostree_status() {
    if [ -n "$FIXTURE" ]; then cat "$FIXTURE/cmd/rpm-ostree-status.json"; else rpm-ostree status --json; fi
}
src_kargs() {
    if [ -n "$FIXTURE" ]; then cat "$FIXTURE/cmd/kargs"; else rpm-ostree kargs; fi
}

# booted_deployment <status-json>: empty when no deployment is booted.
booted_deployment() {
    jq '.deployments[] | select(.booted == true)' <<< "$1"
}

# layered_requests <deployment-json>: every request the origin still carries,
# space-separated. A request the image already satisfies leaves `packages`
# empty and stays in requested-packages, where bootc still counts it.
layered_requests() {
    jq -r '[(.packages // []), (."requested-packages" // []), (."requested-local-packages" // []), (."requested-local-fileoverride-packages" // []), (."requested-base-local-replacements" // []), (."requested-base-removals" // []), (."requested-modules" // [])] | flatten | unique | join(" ")' <<< "$1"
}

# image_name: empty when image-info.json is unreadable.
image_name() {
    jq -r '."image-name" // ""' "$(f $IMAGE_INFO)" 2> /dev/null || true
}

# policy_scope_type: sigstoreSigned on this image, empty when the scope is absent.
policy_scope_type() {
    jq -r --arg s "$VENDOR_SCOPE" '.transports.docker[$s][0].type // ""' "$(f /etc/containers/policy.json)" 2> /dev/null || true
}

fstab_entries() {
    grep -vE '^\s*(#|$)' "$1" 2> /dev/null || true
}

ntfsplus_optin() {
    [ -e "$(f $NTFSPLUS_OPTIN)" ]
}
ntfs_registered() {
    grep -qw ntfs "$(f /proc/filesystems)" 2> /dev/null
}

# Residue of a host that loaded ntfsplus on its own, one path per line. The
# opt-in file carries the same name and is not residue.
ntfsplus_files() {
    grep -rls ntfsplus "$(f /etc/modprobe.d)" "$(f /etc/modules-load.d)" 2> /dev/null | sed "s|^$FIXTURE||" | grep -vx "$NTFSPLUS_OPTIN" || true
}
ntfsplus_kargs() {
    src_kargs | tr ' ' '\n' | grep ntfsplus || true
}
# Residue of a host that loaded the MSI modules on its own: the file
# setup-msi writes is not residue.
msi_files() {
    grep -rlsE 'msi[-_]ec|acpi_ec' "$(f /etc/modules-load.d)" 2> /dev/null | sed "s|^$FIXTURE||" | grep -vx "$MSI_MODULES_LOAD" || true
}
