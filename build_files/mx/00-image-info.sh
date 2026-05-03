#!/usr/bin/bash
# MX block 00: image identity + KDE about-page branding.
#
# Adapted from the Bazzite-DX `00-image-info.sh` pattern:
#  - Updates /usr/share/ublue-os/image-info.json with our image-name and
#    image-ref (replacing the inherited 'bazzite' baseline).
#  - Updates /usr/lib/os-release VARIANT_ID.
#  - Updates /etc/xdg/kcm-about-distrorc (KDE System Settings → About)
#    with Website and Variant. Variant explicitly distinguishes NVIDIA
#    proprietary vs NVIDIA-open from the base flavour.
#
# No GNOME branch: bazzite-mx is KDE-only (Bazzite base = Kinoite).
#
# IMAGE_NAME and IMAGE_VENDOR are passed by the Containerfile as ARG +
# ENV so they're visible to this script inside a RUN step.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

: "${IMAGE_NAME:?IMAGE_NAME must be set by Containerfile ENV}"
: "${IMAGE_VENDOR:?IMAGE_VENDOR must be set by Containerfile ENV}"

IMAGE_INFO=/usr/share/ublue-os/image-info.json
IMAGE_REF="ostree-image-signed:docker://ghcr.io/${IMAGE_VENDOR}/${IMAGE_NAME}"

# image-info.json: image-name + image-ref must align with the fork.
# Fail-fast guard: GNU `sed -i` returns 0 even when the file doesn't
# exist (silent no-op). Without the guard, an upstream removal of the
# file would leave us with a green build and missing branding —
# exactly the Phase 1 kcm-about bug this refactor closes.
[ -f "$IMAGE_INFO" ] || { echo "FAIL: $IMAGE_INFO not found"; exit 1; }
sed -i 's|"image-name": [^,]*|"image-name": "'"$IMAGE_NAME"'"|' "$IMAGE_INFO"
sed -i 's|"image-ref": [^,]*|"image-ref": "'"$IMAGE_REF"'"|' "$IMAGE_INFO"
# image-vendor was still "ublue-os" (inherited from Bazzite base) —
# inconsistent with publishing to ghcr.io/$IMAGE_VENDOR. Phase 9
# closing-branding alignment.
sed -i 's|"image-vendor": [^,]*|"image-vendor": "'"$IMAGE_VENDOR"'"|' "$IMAGE_INFO"

# os-release VARIANT_ID for fork consistency.
[ -f /usr/lib/os-release ] || { echo "FAIL: /usr/lib/os-release not found"; exit 1; }
sed -i "s/^VARIANT_ID=.*/VARIANT_ID=$IMAGE_NAME/" /usr/lib/os-release

# KDE about-page (path: /etc/xdg/kcm-about-distrorc, present on
# Bazzite base — verified 2026-05-02). Bazzite-DX-style pattern.
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
