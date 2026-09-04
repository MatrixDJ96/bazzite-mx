#!/usr/bin/env bash
# Installs what the kmod-builder stage staged, one module per
# build_files/kmods/<name>/source.env. They land under updates/, which depmod
# searches before kernel/, so ours wins over an in-tree copy of the same name.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"
# shellcheck source=lib/kmod.sh
source "$BUILD_FILES/lib/kmod.sh"

KMODS_IN=${KMODS_IN:-/kmods}
KMODS_DIR=$BUILD_FILES/kmods

kver=$(kernel_version)
staged=$KMODS_IN/$kver/updates
[ -d "$staged" ] || die "no modules staged for $kver under $KMODS_IN (staged: $(ls "$KMODS_IN" 2> /dev/null | tr '\n' ' '))"

dest=/usr/lib/modules/$kver/updates
installed=""
for env in "$KMODS_DIR"/*/source.env; do
    [ -e "$env" ] || die "no */source.env under $KMODS_DIR"
    unset KO_NAME KO_VERSION
    # shellcheck disable=SC1090
    source "$env"
    [ -f "$staged/$KO_NAME.ko" ] || die "$staged/$KO_NAME.ko missing (builder and $env disagree)"
    install -Dm644 "$staged/$KO_NAME.ko" "$dest/$KO_NAME.ko"
    installed+=" $KO_NAME${KO_VERSION:+ $KO_VERSION}"
done

depmod -a "$kver"

for env in "$KMODS_DIR"/*/source.env; do
    unset KO_NAME KO_VERSION
    # shellcheck disable=SC1090
    source "$env"
    ko=$dest/$KO_NAME.ko
    assert_module "$ko" "$kver" "${KO_VERSION:-}" || exit 1
    # modprobe prints the /lib/modules form and /lib is a symlink to usr/lib,
    # so the two paths are compared canonicalised. A refusal is kept out of
    # the pipeline's status: under errexit it would end the script at the
    # assignment, before the die below names the module.
    resolved=$({ modprobe -S "$kver" -n --show-depends "$KO_NAME" 2>&1 || true; } | awk '$1 == "insmod" { print $2 }' | tail -n1)
    [ -n "$resolved" ] && [ "$(realpath "$resolved")" = "$(realpath "$ko")" ] || die "modprobe $KO_NAME resolves to '$resolved', not $ko"
    grep -q "^updates/$KO_NAME.ko:" "/usr/lib/modules/$kver/modules.dep" || die "$KO_NAME.ko not in modules.dep"
done

log "kmods:${installed} in $dest for $kver"
