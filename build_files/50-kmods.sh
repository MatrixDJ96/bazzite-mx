#!/usr/bin/env bash
# Kernel modules for the MSI laptop of the fleet (decision 1.5a, 1.5g): one
# per build_files/kmods/<name>/source.env (msi-ec, acpi_ec), compiled by the
# Containerfile's kmod-builder stage (build-kmods.sh) against the base's own
# kernel-devel and bound here at /kmods/<kver>/updates/*.ko. They go to
# /usr/lib/modules/<kver>/updates/, where depmod looks before kernel/, so the
# out-of-tree msi-ec wins over the in-tree copy. Asserts (lib/kmod.sh): each
# module readable, stamped for the image's one kernel and at source.env's
# version, resolved by modprobe to our copy, listed in modules.dep. Nothing
# loads them at boot: `ujust setup-msi enable` does, on the MSI host. Why,
# with sources: docs/divergences.md § MSI laptop.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"
# shellcheck source=lib/kmod.sh
source "$BUILD_FILES/lib/kmod.sh"

KMODS_IN=${KMODS_IN:-/kmods}
KMODS_DIR=$BUILD_FILES/kmods

# --- the steps ----------------------------------------------------------------

# Sets KO_NAME and KO_VERSION from one source.env; KO_VERSION stays empty
# when the module declares none.
read_source_env() {
    local source_env=$1

    unset KO_NAME KO_VERSION
    # shellcheck disable=SC1090
    source "$source_env"
}

# Prints the staged directory for the kernel, the builder's tree checked.
staged_directory() {
    local kernel=$1
    local staged=$KMODS_IN/$kernel/updates

    if [ ! -d "$staged" ]; then
        fail_build "no modules staged for $kernel under $KMODS_IN" \
            "(staged: $(ls "$KMODS_IN" 2> /dev/null | tr '\n' ' '))"
    fi

    echo "$staged"
}

# Prints one ` <name>[ <version>]` per module installed, the log's summary.
install_staged_modules() {
    local staged=$1
    local dest=$2
    local source_env installed=""

    for source_env in "$KMODS_DIR"/*/source.env; do
        if [ ! -e "$source_env" ]; then
            fail_build "no */source.env under $KMODS_DIR"
        fi

        read_source_env "$source_env"

        if [ ! -f "$staged/$KO_NAME.ko" ]; then
            fail_build "$staged/$KO_NAME.ko missing (builder and $source_env disagree)"
        fi

        install -Dm644 "$staged/$KO_NAME.ko" "$dest/$KO_NAME.ko"
        installed+=" $KO_NAME${KO_VERSION:+ $KO_VERSION}"
    done

    echo "$installed"
}

# The module is readable, built for the kernel, at its version, and modprobe
# would load our file. modprobe prints the /lib/modules form and /lib is a
# symlink to usr/lib, so the two paths are compared canonicalised; a refusal
# is kept out of the pipeline's status so the message can name the module.
require_module_resolves() {
    local kernel=$1
    local module_file=$2
    local resolved

    if ! assert_module "$module_file" "$kernel" "${KO_VERSION:-}"; then
        exit 1
    fi

    resolved=$({ modprobe -S "$kernel" -n --show-depends "$KO_NAME" 2>&1 || true; } \
        | awk '$1 == "insmod" { print $2 }' \
        | tail -n1)

    if [ -z "$resolved" ] || [ "$(realpath "$resolved")" != "$(realpath "$module_file")" ]; then
        fail_build "modprobe $KO_NAME resolves to '$resolved', not $module_file"
    fi

    if ! grep -q "^updates/$KO_NAME.ko:" "/usr/lib/modules/$kernel/modules.dep"; then
        fail_build "$KO_NAME.ko not in modules.dep"
    fi
}

# --- main ---------------------------------------------------------------------

kernel=$(kernel_version)
staged=$(staged_directory "$kernel")
dest=/usr/lib/modules/$kernel/updates

installed=$(install_staged_modules "$staged" "$dest")
depmod -a "$kernel"

for source_env in "$KMODS_DIR"/*/source.env; do
    read_source_env "$source_env"
    require_module_resolves "$kernel" "$dest/$KO_NAME.ko"
done

log "kmods:${installed} in $dest for $kernel"
