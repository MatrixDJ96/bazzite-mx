#!/usr/bin/env bash
# Installs what the kmod-builder stage staged, one module per
# build_files/kmods/<name>/source.env. They land under updates/, which depmod
# searches before kernel/, so ours wins over an in-tree copy of the same name.
#
# Usage: run by build.sh; no arguments. The staged tree is /kmods, the
#   Containerfile's mount of the builder stage.
# Writes: /usr/lib/modules/<kernel>/updates/<KO_NAME>.ko per module, and the
#   depmod index of that kernel.
# Exit status: 0 done; the build stops on a `FAIL: …` line, or on install's own
#   for a module the kmod-builder stage did not produce.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"
# shellcheck source=lib/kmod.sh
source "$BUILD_FILES/lib/kmod.sh"

KMODS_IN=/kmods
KMODS_DIR=$BUILD_FILES/kmods

# --- the steps ----------------------------------------------------------------

# require_module_resolves <kernel> <name> <version>: the module is readable,
# built for the kernel, at its version, and modprobe would load our file.
# modprobe prints the /lib/modules form and /lib is a symlink to usr/lib, so
# the two paths are compared canonicalised; a refusal is kept out of the
# pipeline's status so the message can name the module.
require_module_resolves() {
    local kernel=$1
    local name=$2
    local version=$3
    local module_file=/usr/lib/modules/$kernel/updates/$name.ko
    local resolved

    if ! assert_module "$module_file" "$kernel" "$version"; then
        exit 1
    fi

    resolved=$({ modprobe -S "$kernel" -n --show-depends "$name" 2>&1 || true; } \
        | awk '$1 == "insmod" { print $2 }' \
        | tail -n1)

    if [ -z "$resolved" ] || [ "$(realpath "$resolved")" != "$(realpath "$module_file")" ]; then
        fail_build "modprobe $name resolves to '$resolved', not $module_file"
    fi
}

# --- main ---------------------------------------------------------------------

kernel=$(kernel_version)
staged=$KMODS_IN/$kernel/updates
dest=/usr/lib/modules/$kernel/updates
names=()
versions=()

# The one walk of the source.env files, in this shell: what a walk inside
# `$( )` reads does not survive it (docs/gotchas.md § A step run in a command
# substitution sets its flags in a subshell), and the resolve pass needs the
# names again after depmod has indexed them.
for source_env in "$KMODS_DIR"/*/source.env; do
    unset KO_NAME KO_VERSION
    # shellcheck disable=SC1090
    source "$source_env"

    install -Dm644 "$staged/$KO_NAME.ko" "$dest/$KO_NAME.ko"
    names+=("$KO_NAME")
    versions+=("${KO_VERSION:-}")
done

depmod -a "$kernel"

installed=""

for index in "${!names[@]}"; do
    require_module_resolves "$kernel" "${names[index]}" "${versions[index]}"
    installed+=" ${names[index]}${versions[index]:+ ${versions[index]}}"
done

log "kmods:${installed} in $dest for $kernel"
