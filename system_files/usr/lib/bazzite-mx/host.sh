#!/usr/bin/env bash
# What the verify-host, migrate, ntfsplus-setup and msi-setup helpers read
# about the host, the fstab type rewrite and the verification migrate and
# ntfsplus-setup judge it on, and the error helpers all four call, the
# privilege one migrate, ntfsplus-setup and msi-setup. Sourced by those four
# and by tests/helpers/verify-host.sh, never run; the sourcing script sets
# its own `set` options.
#
# FIXTURE=<dir>: every file is read under <dir> and every command's output
# under <dir>/cmd/, so a helper runs on a synthetic host in the smoke tests;
# ntfs3_available (the running kernel) and fstab_verify_output (findmnt
# --verify on the running root) read the host whatever the fixture: their
# callers (migrate apply, ntfsplus-setup enable and disable) run under sudo,
# which drops FIXTURE.
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

# reason_on_one_line <text>: a tool's diagnostic on one line, a blank between
# items and none at either end, `no output` when the tool printed nothing.
# An `ERROR:` line carries the reason inside itself: a diagnostic left to the
# tool reaches the log as a second, unprefixed line.
reason_on_one_line() {
    local reason=${1//$'\n'/ }

    reason=$(sed 's/^ *//;s/ *$//' <<< "$reason" || true)
    echo "${reason:-no output}"
}

# A function a caller runs under `if` returns a status; the two exceptions
# are named where they happen (switch_fstab_rows).
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

# unescape_fstab_field <field>: the field as libmount reads it. fstab(5)
# writes a space as `\040`: a backslash and exactly three octal digits, and
# nothing else is an escape (`\x20` and `\c` stay as they are, which printf
# '%b' would not honour).
unescape_fstab_field() {
    local field=$1
    local decoded='' byte

    while [[ $field =~ ^([^\\]*)\\([0-7][0-7][0-7])(.*)$ ]]; do
        printf -v byte "\\${BASH_REMATCH[2]}"
        decoded+=${BASH_REMATCH[1]}$byte
        field=${BASH_REMATCH[3]}
    done

    printf '%s' "$decoded$field"
}

# unescaped_on_one_line: the mount points on stdin, one per line as fstab
# writes them, on one line as libmount reads them, a blank between.
unescaped_on_one_line() {
    local point line=""

    while IFS= read -r point; do
        line+="$(unescape_fstab_field "$point") "
    done

    printf '%s' "${line% }"
}

# src_block_device <fstab source>: the device the source of an fstab row
# resolves to, empty only when it is absent (an unplugged volume). The field
# is read as fstab(5) writes it (unescape_fstab_field). UUID=, LABEL=,
# PARTUUID= and PARTLABEL= go through findfs(8), whose `unable to resolve`
# is the one answer that means absent: any other failure ends the helper
# with `ERROR:`, an unreadable probe being no evidence of absence. A path
# stands for itself when it exists. Fixture: "<source> <device>" lines in
# cmd/devices, the source unescaped and compared whole. Its one caller
# (verify-host) assigns it in an `if` body, where `set -e` ends the run on
# the ERROR exit: status 1, the header's for a findfs that could not answer.
src_block_device() {
    local source answer device

    source=$(unescape_fstab_field "$1")

    if [ -n "$FIXTURE" ]; then
        # Through the environment: awk -v would unescape a `\040` on its own.
        FSTAB_SOURCE="$source" awk '{
            fstab_source = $0
            sub(/[[:space:]]+[^[:space:]]+[[:space:]]*$/, "", fstab_source)
            if (fstab_source == ENVIRON["FSTAB_SOURCE"]) {
                print $NF
            }
        }' "$FIXTURE/cmd/devices"
        return 0
    fi

    case "$source" in
        UUID=* | LABEL=* | PARTUUID=* | PARTLABEL=*)
            answer=$(LC_ALL=C findfs "$source" 2>&1 || true)
            device=$(grep -m 1 '^/' <<< "$answer" || true)

            if [ -n "$device" ]; then
                echo "$device"
            elif [[ $answer != *"unable to resolve"* ]]; then
                exit_with_error "findfs could not read $source: ${answer:-no output}"
            fi
            ;;
        *)
            if [ -e "$source" ]; then
                echo "$source"
            fi
            ;;
    esac
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

# --- fstab and NTFS -----------------------------------------------------------

# mount_fstype <target>: the type mounted at <target>, the point as libmount
# reads it (a space is a space, not `\040`), empty when nothing is; of a
# stack the topmost (an `x-systemd.automount` row lists `autofs` and, once
# triggered, the volume's type over it: docs/gotchas.md § A triggered
# automount stacks the volume's type over `autofs`). A fixture lists
# "<target> <fstype>" lines under cmd/mounts (blanks or a tab between,
# trailing blanks ignored), the target compared whole (a prefix is not a
# mount) and passed through the environment: awk -v would unescape a `\040`
# on its own. A fixture spells the target as fstab does; on a host findmnt
# prints /var/mnt for /mnt, which ostree links to var/mnt.
mount_fstype() {
    local mount_point=$1

    if [ -n "$FIXTURE" ]; then
        MOUNT_TARGET="$mount_point" awk '{
            target = $0
            sub(/[[:space:]]+[^[:space:]]+[[:space:]]*$/, "", target)
            if (target == ENVIRON["MOUNT_TARGET"]) {
                print $NF
            }
        }' "$FIXTURE/cmd/mounts" | tail -n 1
        return 0
    fi

    findmnt -n -o FSTYPE --mountpoint "$mount_point" 2> /dev/null | tail -n 1 || true
}

# fstab_entries <fstab>: the rows, comments and blank lines dropped.
# A CRLF table keeps its `\r` in the rewriters; here it is dropped so the type
# of a row that ends at its type reads as the type and not as `ntfs\r`.
fstab_entries() {
    local fstab=$1

    grep -vE '^\s*(#|$)' "$fstab" 2> /dev/null | sed 's/\r$//' || true
}

# replace_fstab_type <from> <to> <in> <out>: the type column of every entry
# whose type is exactly <from> becomes <to>; comments, blank lines and every
# other byte but errors=remount-ro pass through unchanged. The type may end
# the row: fstab(5) makes the last three fields optional. A row may start with
# blanks, which libmount skips (docs/gotchas.md § A fstab row may start with
# whitespace). Only the first non-blank character of a line opens a comment,
# so a source field may carry a `#` (docs/gotchas.md § A `#` inside an fstab
# field is not a comment). ntfsplus-setup rewrites both ways, migrate only
# ntfs -> ntfs3.
# Towards ntfs every ntfs row without an errors= option, switched or already
# ntfs, gains `errors=remount-ro`, which NTFSPLUS needs to mount a dirty or
# hibernated volume read-only; a row turning ntfs3 loses it, ntfs3 refusing
# the option (docs/divergences.md § NTFSPLUS as a per-host opt-in); a row
# whose only option it is, followed by dump and pass, keeps it and ntfs3
# refuses the row.
replace_fstab_type() {
    local from=$1 to=$2 input=$3 output=$4
    local fields='[[:space:]]*[^#[:space:]][^[:space:]]*[[:space:]]+[^[:space:]]+[[:space:]]+'
    local row="^(${fields})${from}([[:space:]]|\$)" typed="^(${fields}${to})"
    local option=errors=remount-ro edits=()

    case $to in
        ntfs)
            edits=(
                -e "s/${row}/\\1${to}\\2/"
                -e "/${typed}[[:space:]]+([^[:space:]]*,)?errors=/b"
                -e "s/${typed}([[:space:]]+[^[:space:]]+)/\\1\\2,${option}/"
                -e "s/${typed}([[:space:]]*)\$/\\1 ${option}\\2/"
            )
            ;;
        ntfs3)
            edits=(
                -e "/${row}/!b"
                -e "s/${row}/\\1${to}\\2/"
                -e "s/${typed}([[:space:]]+[^[:space:]]*),${option}(,|[[:space:]]|\$)/\\1\\2\\3/"
                -e "s/${typed}([[:space:]]+)${option},/\\1\\2/"
                -e "s/${typed}[[:space:]]+${option}([[:space:]]*)\$/\\1\\2/"
            )
            ;;
    esac

    sed -E "${edits[@]}" "$input" > "$output"
}

# fstab_verify_output <fstab>: everything findmnt --verify prints on that
# table, the summary line included, messages in C so the callers can read
# them; the status is not the verdict, a stale nofail row making it 1 on any
# table that carries one (docs/gotchas.md § `findmnt --verify` reports an
# unplugged `nofail` volume as an error). The findings go to stdout, the
# summary to stderr: into a pipe stdout is block-buffered and the summary
# would land inside a cut line past 4096 bytes, so stdout is line-buffered.
fstab_verify_output() {
    local fstab=$1

    LC_ALL=C stdbuf -oL findmnt --verify --tab-file "$fstab" 2>&1 || true
}

FSTAB_VERIFY_SUMMARY='^(Success, no errors or warnings detected'
FSTAB_VERIFY_SUMMARY+='|[0-9]+ parse errors?, [0-9]+ errors?, [0-9]+ warnings?)$'

# fstab_verify_answers <fstab>: findmnt gave its verdict on that table, the
# summary line it ends with (`Success, no errors or warnings detected` or
# `N parse errors, N errors, N warnings`). A findmnt that never ran prints
# nothing, one that died on a malformed row prints its diagnostic and no
# summary (docs/gotchas.md § `findmnt --verify` reports an unplugged `nofail`
# volume as an error); a caller judging a rewrite refuses both instead of
# reading an empty error set as a clean one.
fstab_verify_answers() {
    local fstab=$1
    local output

    output=$(fstab_verify_output "$fstab")
    grep -qE "$FSTAB_VERIFY_SUMMARY" <<< "$output"
}

# fstab_verify_errors <fstab>: findmnt's `[E]` lines on that table, each
# prefixed with its mount point, sorted. A stale nofail row (a volume that is
# not plugged in) is one before any rewrite, so a rewrite is judged on the
# errors it adds, never on the count.
fstab_verify_errors() {
    local fstab=$1

    fstab_verify_output "$fstab" \
        | awk '/^[^[:space:]]/ { target = $0 } /^[[:space:]]*\[E\]/ { print target ": " $0 }' \
        | tr -s ' ' \
        | sort -u
}

# new_verify_errors <before> <after>: the error lines <after> has and <before>
# has not; empty when the rewrite adds none.
new_verify_errors() {
    local before=$1
    local after=$2

    comm -13 <(fstab_verify_errors "$before") <(fstab_verify_errors "$after")
}

ntfsplus_optin() {
    [ -e "$(host_file $NTFSPLUS_OPTIN)" ]
}

ntfs_registered() {
    grep -qw ntfs "$(host_file /proc/filesystems)" 2> /dev/null
}

# Status 0 when the running kernel has ntfs3 registered or loadable. Both
# rewrites back to ntfs3 ask it first: a host whose kernel has no ntfs3 would
# come back from the reboot with the volumes unmounted.
ntfs3_available() {
    if grep -qw ntfs3 /proc/filesystems; then
        return 0
    fi

    modprobe -n ntfs3 2> /dev/null
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

# ntfsplus_kargs <kernel arguments>: the ntfsplus arguments among them, one
# per line, each once and in the order the command line carries them. A
# duplicate would make the caller's `rpm-ostree kargs --delete=` run twice on
# the same token, the second finding nothing. The reading is the caller's, so
# that a failed `rpm-ostree kargs` is seen instead of reading as a host
# without the arguments.
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
