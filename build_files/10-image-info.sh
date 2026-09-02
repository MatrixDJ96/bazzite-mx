#!/usr/bin/env bash
# Identity: image-info.json, os-release and the KDE About page name this
# image, not the base.
#
# Usage: run by build.sh; no arguments. Reads the build args IMAGE_NAME,
#   IMAGE_VENDOR and VERSION from the environment (the Containerfile passes
#   them); an empty VERSION marks a sandbox or pre-flight build.
# Writes: /usr/share/ublue-os/image-info.json, /usr/lib/os-release and, when
#   the base ships it, /etc/xdg/kcm-about-distrorc.
# Exit status: 0 done; the build stops on a `FAIL: …` line.

# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

IMAGE_INFO=/usr/share/ublue-os/image-info.json
OS_RELEASE=/usr/lib/os-release
KDE_ABOUT_PAGE=/etc/xdg/kcm-about-distrorc

# --- the steps ----------------------------------------------------------------

require_build_args() {
    if [ -z "${IMAGE_NAME:-}" ]; then
        fail_build "IMAGE_NAME build arg missing"
    fi

    if [ -z "${IMAGE_VENDOR:-}" ]; then
        fail_build "IMAGE_VENDOR build arg missing"
    fi
}

# Prints the version the base calls itself, read from its image-info.json.
base_version() {
    local version

    if [ ! -f "$IMAGE_INFO" ]; then
        fail_build "$IMAGE_INFO missing from the base"
    fi

    version=$(jq -r '.version // empty' "$IMAGE_INFO")

    if [ -z "$version" ]; then
        fail_build "base image-info.json has no version"
    fi

    echo "$version"
}

# The base's version moves to base-version; the rest names this image. The
# rewrite lands on a fresh inode through the rename.
write_image_info() {
    local base_version=$1
    local version=$2
    local image_ref="ostree-image-signed:docker://ghcr.io/${IMAGE_VENDOR}/${IMAGE_NAME}"
    local pretty="${IMAGE_NAME} ${version} (Bazzite ${base_version})"

    jq --arg name "$IMAGE_NAME" \
        --arg vendor "$IMAGE_VENDOR" \
        --arg ref "$image_ref" \
        --arg version "$version" \
        --arg pretty "$pretty" \
        '."base-version" = .version
         | ."image-name" = $name
         | ."image-vendor" = $vendor
         | ."image-ref" = $ref
         | .version = $version
         | ."version-pretty" = $pretty' "$IMAGE_INFO" > "$IMAGE_INFO.new"
    mv -f "$IMAGE_INFO.new" "$IMAGE_INFO"
}

# VARIANT_ID is always there to replace; IMAGE_ID is appended when the base
# does not carry the key.
write_os_release() {
    local version=$1
    local image_id="IMAGE_ID=\"${IMAGE_NAME}-${version}\""

    sed -i "s/^VARIANT_ID=.*/VARIANT_ID=${IMAGE_NAME}/" "$OS_RELEASE"
    sed -i "s/^IMAGE_ID=.*/${image_id}/" "$OS_RELEASE"

    if ! grep -q "^IMAGE_ID=" "$OS_RELEASE"; then
        echo "$image_id" >> "$OS_RELEASE"
    fi
}

# The About page of Plasma's System Settings: the repository as the website
# and the flavour as the variant.
write_kde_about_page() {
    local variant

    if [ ! -f "$KDE_ABOUT_PAGE" ]; then
        return 0
    fi

    case "$IMAGE_NAME" in
        *nvidia-open)
            variant="MX (NVIDIA open)"
            ;;
        *nvidia)
            variant="MX (NVIDIA)"
            ;;
        *)
            variant="MX"
            ;;
    esac

    sed -i "s|^Website=.*|Website=https://github.com/${IMAGE_VENDOR}/${IMAGE_NAME}|" \
        "$KDE_ABOUT_PAGE"
    sed -i "s/^Variant=.*/Variant=${variant}/" "$KDE_ABOUT_PAGE"
}

# --- main ---------------------------------------------------------------------

require_build_args
base_version=$(base_version)

# The .dev suffix keeps a sandbox or pre-flight image from being mistaken for
# a release.
version=${VERSION:-${base_version}.dev}

write_image_info "$base_version" "$version"
write_os_release "$version"
write_kde_about_page

log "image-info: ${IMAGE_NAME} ${version} on Bazzite ${base_version}"
