#!/usr/bin/env bash
# What the verify-host, migrate and msi-setup helpers read about the host,
# the error helpers all three call, the privilege one migrate and msi-setup.
# Sourced by those three and by tests/helpers/verify-host.sh, never run; the
# sourcing script sets its own `set` options.
#
# FIXTURE=<dir>: every file is read under <dir> and every command's output
# under <dir>/cmd/, so a helper runs on a synthetic host in the smoke tests.
# Output contract: `ERROR: <reason>` on stderr is what the recipes and the
# tests read.

FIXTURE=${FIXTURE:-}
VENDOR_SCOPE=ghcr.io/matrixdj96
IMAGE_INFO=/usr/share/ublue-os/image-info.json

# Written by bazzite-mx-msi-setup enable.
MSI_MODULES_LOAD=/etc/modules-load.d/bazzite-mx-msi.conf

# --- errors and privileges ----------------------------------------------------

# reason_on_one_line <text>: a tool's diagnostic on one line, a blank between
# items and none at either end, `no output` when the tool printed nothing.
# An `ERROR:` line carries the reason inside itself: a diagnostic left to the
# tool reaches the log as a second, unprefixed line.
reason_on_one_line() {
    local reason=${1//$'\n'/ }

    reason=$(sed 's/^ *//;s/ *$//' <<< "$reason" || true)
    echo "${reason:-no output}"
}

exit_with_error() {
    echo "ERROR: $*" >&2
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

# The recipe runs the helper through sudo, and root's `flatpak list` sees
# the system installation and root's own user one, never the invoking
# user's: that scope is listed as SUDO_USER (docs/gotchas.md § Root's
# `flatpak list` misses the invoking user's installation). A flatpak that
# cannot list is not a host without Flatpaks: each status is kept and
# the caller names the reason.
src_flatpaks() {
    if [ -n "$FIXTURE" ]; then
        cat "$FIXTURE/cmd/flatpaks"
        return 0
    fi

    if ! flatpak list --app --system --columns=application; then
        return 1
    fi

    if [ -n "${SUDO_USER:-}" ]; then
        runuser -u "$SUDO_USER" -- flatpak list --app --user --columns=application
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
# (docs/gotchas.md § An inactive package request stays in the origin and
# keeps bootc incompatible).
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

# --- residue ------------------------------------------------------------------

# Residue of a host that loaded ntfsplus on its own or kept
# /etc/modprobe.d/bazzite-mx-ntfsplus.conf, one path per line.
ntfsplus_files() {
    grep -rls ntfsplus "$(host_file /etc/modprobe.d)" "$(host_file /etc/modules-load.d)" \
        2> /dev/null \
        | sed "s|^$FIXTURE||" || true
}

# ntfsplus_kargs <kernel arguments>: the ntfsplus arguments among them, one
# per line, each once and in the order the command line carries them. The
# reading is the caller's, so that a failed `rpm-ostree kargs` is seen instead
# of reading as a host without the arguments.
ntfsplus_kargs() {
    local kargs=$1

    tr ' ' '\n' <<< "$kargs" | grep ntfsplus | awk '!seen[$0]++' || true
}

msi_optin() {
    [ -e "$(host_file $MSI_MODULES_LOAD)" ]
}

# Residue of a host that loaded the MSI modules on its own: the file
# setup-msi writes is not residue.
msi_files() {
    grep -rlsE 'msi[-_]ec|acpi_ec' "$(host_file /etc/modules-load.d)" 2> /dev/null \
        | sed "s|^$FIXTURE||" \
        | grep -vx "$MSI_MODULES_LOAD" || true
}
