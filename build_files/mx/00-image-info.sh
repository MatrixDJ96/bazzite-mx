#!/usr/bin/bash
# MX block 00: image identity + KDE about-page branding.
#  - /usr/share/ublue-os/image-info.json: image-name, image-ref, image-vendor.
#  - /usr/lib/os-release: VARIANT_ID.
#  - /etc/xdg/kcm-about-distrorc (KDE System Settings → About): Website +
#    Variant (Variant distinguishes NVIDIA proprietary vs NVIDIA-open).
#
# KDE-only (Bazzite base = Kinoite); no GNOME branch.
# IMAGE_NAME and IMAGE_VENDOR arrive from the Containerfile as ARG + ENV.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

: "${IMAGE_NAME:?IMAGE_NAME must be set by Containerfile ENV}"
: "${IMAGE_VENDOR:?IMAGE_VENDOR must be set by Containerfile ENV}"

IMAGE_INFO=/usr/share/ublue-os/image-info.json
IMAGE_REF="ostree-image-signed:docker://ghcr.io/${IMAGE_VENDOR}/${IMAGE_NAME}"

# image-info.json: align image-name, image-ref, image-vendor with the fork.
# Fail-fast guard: GNU `sed -i` returns 0 even when the file doesn't exist
# (silent no-op), which would otherwise produce a green build with missing
# branding if upstream ever removes the file.
[ -f "$IMAGE_INFO" ] || { echo "FAIL: $IMAGE_INFO not found"; exit 1; }
sed -i 's|"image-name": [^,]*|"image-name": "'"$IMAGE_NAME"'"|' "$IMAGE_INFO"
sed -i 's|"image-ref": [^,]*|"image-ref": "'"$IMAGE_REF"'"|' "$IMAGE_INFO"
sed -i 's|"image-vendor": [^,]*|"image-vendor": "'"$IMAGE_VENDOR"'"|' "$IMAGE_INFO"

# os-release VARIANT_ID for fork consistency.
[ -f /usr/lib/os-release ] || { echo "FAIL: /usr/lib/os-release not found"; exit 1; }
sed -i "s/^VARIANT_ID=.*/VARIANT_ID=$IMAGE_NAME/" /usr/lib/os-release

# KDE about-page.
KCM=/etc/xdg/kcm-about-distrorc
[ -f "$KCM" ] || { echo "FAIL: $KCM not found (Bazzite KDE layout changed?)"; exit 1; }
case "$IMAGE_NAME" in
    *nvidia-open) VARIANT="Bazzite-MX (NVIDIA Open)" ;;
    *nvidia)      VARIANT="Bazzite-MX (NVIDIA)" ;;
    *)            VARIANT="Bazzite-MX" ;;
esac
sed -i "s|^Website=.*|Website=https://github.com/MatrixDJ96/bazzite-mx|" "$KCM"
sed -i "s/^Variant=.*/Variant=$VARIANT/" "$KCM"

echo "::endgroup::"
