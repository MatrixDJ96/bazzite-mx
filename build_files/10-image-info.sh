#!/usr/bin/env bash
# Identity: image-info.json, os-release and the KDE About page name this
# image, not the base. IMAGE_NAME, IMAGE_VENDOR and VERSION come from the
# Containerfile as build args.
# shellcheck source=lib/env.sh
source "$(dirname "$(realpath "$0")")/lib/env.sh"

: "${IMAGE_NAME:?IMAGE_NAME build arg missing}"
: "${IMAGE_VENDOR:?IMAGE_VENDOR build arg missing}"
INFO=/usr/share/ublue-os/image-info.json
[ -f "$INFO" ] || die "$INFO missing from the base"

base_version=$(jq -r '.version // empty' "$INFO")
[ -n "$base_version" ] || die "base image-info.json has no version"
# An empty VERSION means a sandbox or pre-flight build: the .dev suffix keeps
# such an image from being mistaken for a release.
version=${VERSION:-${base_version}.dev}
image_ref="ostree-image-signed:docker://ghcr.io/${IMAGE_VENDOR}/${IMAGE_NAME}"

jq --arg name "$IMAGE_NAME" --arg vendor "$IMAGE_VENDOR" --arg ref "$image_ref" \
    --arg version "$version" --arg pretty "${IMAGE_NAME} ${version} (Bazzite ${base_version})" \
    '."base-version" = .version
     | ."image-name" = $name | ."image-vendor" = $vendor | ."image-ref" = $ref
     | .version = $version | ."version-pretty" = $pretty' "$INFO" > "$INFO.new"
mv -f "$INFO.new" "$INFO"

sed -i "s/^VARIANT_ID=.*/VARIANT_ID=${IMAGE_NAME}/" /usr/lib/os-release
sed -i "s/^IMAGE_ID=.*/IMAGE_ID=\"${IMAGE_NAME}-${version}\"/" /usr/lib/os-release
grep -q "^IMAGE_ID=" /usr/lib/os-release || echo "IMAGE_ID=\"${IMAGE_NAME}-${version}\"" >> /usr/lib/os-release

if [ -f /etc/xdg/kcm-about-distrorc ]; then
    sed -i "s|^Website=.*|Website=https://github.com/${IMAGE_VENDOR}/${IMAGE_NAME}|" /etc/xdg/kcm-about-distrorc
    case "$IMAGE_NAME" in
        *nvidia-open) sed -i "s/^Variant=.*/Variant=MX (NVIDIA open)/" /etc/xdg/kcm-about-distrorc ;;
        *nvidia) sed -i "s/^Variant=.*/Variant=MX (NVIDIA)/" /etc/xdg/kcm-about-distrorc ;;
        *) sed -i "s/^Variant=.*/Variant=MX/" /etc/xdg/kcm-about-distrorc ;;
    esac
fi

log "image-info: ${IMAGE_NAME} ${version} on Bazzite ${base_version}"
