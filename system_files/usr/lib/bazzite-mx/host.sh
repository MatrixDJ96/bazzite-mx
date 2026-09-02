#!/usr/bin/env bash
# What verify-host and migrate both read about this host: the booted
# deployment and its origin, the rpm-ostree requests bootc still counts, the
# signing scope in force, fstab's rows, the ntfsplus residue. One fixture
# routing for the smoke tests (FIXTURE=<dir>: files read under <dir>,
# command outputs under <dir>/cmd/). Sourced by the two helpers, never run.

FIXTURE=${FIXTURE:-}
VENDOR_SCOPE=ghcr.io/matrixdj96
IMAGE_INFO=/usr/share/ublue-os/image-info.json

# f <path>: the file to read (the fixture prefixes the path).
f() { echo "$FIXTURE$1"; }

# Command sources: the fixture replaces the command with a recorded output.
src_rpm_ostree_status() {
    if [ -n "$FIXTURE" ]; then cat "$FIXTURE/cmd/rpm-ostree-status.json"; else rpm-ostree status --json; fi
}
src_kargs() {
    if [ -n "$FIXTURE" ]; then cat "$FIXTURE/cmd/kargs"; else rpm-ostree kargs; fi
}

# booted_deployment <status-json>: the booted deployment, empty when none.
booted_deployment() {
    jq '.deployments[] | select(.booted == true)' <<< "$1"
}

# layered_requests <deployment-json>: every package, local package, file
# override, base replacement, base removal and module the origin requests,
# space-separated (refutation 2.11: a request the image already satisfies
# leaves `packages` empty but stays in requested-packages, where bootc
# still reads it: the hub after its first v2 boot, 2026-09-03).
layered_requests() {
    jq -r '[(.packages // []), (."requested-packages" // []), (."requested-local-packages" // []), (."requested-local-fileoverride-packages" // []), (."requested-base-local-replacements" // []), (."requested-base-removals" // []), (."requested-modules" // [])] | flatten | unique | join(" ")' <<< "$1"
}

# image_name: the name the booted image gives itself, empty when unreadable.
image_name() {
    jq -r '."image-name" // ""' "$(f $IMAGE_INFO)" 2> /dev/null || true
}

# policy_scope_type: the type of the vendor scope in policy.json
# (sigstoreSigned on a v2 image), empty when the scope is absent.
policy_scope_type() {
    jq -r --arg s "$VENDOR_SCOPE" '.transports.docker[$s][0].type // ""' "$(f /etc/containers/policy.json)" 2> /dev/null || true
}

# fstab_entries <fstab>: the rows that are neither comments nor blank.
fstab_entries() {
    grep -vE '^\s*(#|$)' "$1" 2> /dev/null || true
}

# ntfsplus residue: files naming the module and kernel arguments (one per
# line), both empty on a clean host.
ntfsplus_files() {
    grep -rls ntfsplus "$(f /etc/modprobe.d)" "$(f /etc/modules-load.d)" 2> /dev/null | sed "s|^$FIXTURE||" || true
}
ntfsplus_kargs() {
    src_kargs | tr ' ' '\n' | grep ntfsplus || true
}
