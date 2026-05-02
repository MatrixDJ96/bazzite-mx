#!/usr/bin/bash
# MX block 00: image identity + KDE about-page branding.
#
# Adattato dal pattern Bazzite-DX `00-image-info.sh`:
#  - Aggiorna /usr/share/ublue-os/image-info.json con image-name e
#    image-ref nostri (al posto del 'bazzite' baseline ereditato).
#  - Aggiorna /usr/lib/os-release VARIANT_ID.
#  - Aggiorna /etc/xdg/kcm-about-distrorc (KDE System Settings → About)
#    con Website e Variant. Il Variant differenzia esplicitamente
#    NVIDIA proprietary e NVIDIA-open dal flavor base.
#
# Niente branche gnome: bazzite-mx è KDE-only (Bazzite base = Kinoite).
#
# Le variabili IMAGE_NAME e IMAGE_VENDOR sono passate dal Containerfile
# come ARG + ENV per essere visibili a questo script in un RUN.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

: "${IMAGE_NAME:?IMAGE_NAME must be set by Containerfile ENV}"
: "${IMAGE_VENDOR:?IMAGE_VENDOR must be set by Containerfile ENV}"

IMAGE_INFO=/usr/share/ublue-os/image-info.json
IMAGE_REF="ostree-image-signed:docker://ghcr.io/${IMAGE_VENDOR}/${IMAGE_NAME}"

# image-info.json: image-name + image-ref vanno allineati al fork.
# Guard fail-fast: GNU `sed -i` ritorna 0 anche se il file non esiste
# (silent no-op). Senza guard, una rimozione upstream del file ci
# lascerebbe build green con branding mancante — exactly il bug
# Phase 1 di kcm-about che il refactor sta sistemando.
[ -f "$IMAGE_INFO" ] || { echo "FAIL: $IMAGE_INFO not found"; exit 1; }
sed -i 's|"image-name": [^,]*|"image-name": "'"$IMAGE_NAME"'"|' "$IMAGE_INFO"
sed -i 's|"image-ref": [^,]*|"image-ref": "'"$IMAGE_REF"'"|' "$IMAGE_INFO"

# os-release VARIANT_ID per coerenza col fork.
[ -f /usr/lib/os-release ] || { echo "FAIL: /usr/lib/os-release not found"; exit 1; }
sed -i "s/^VARIANT_ID=.*/VARIANT_ID=$IMAGE_NAME/" /usr/lib/os-release

# KDE about-page (path: /etc/xdg/kcm-about-distrorc, esiste su
# Bazzite base — verificato 2026-05-02). Pattern Bazzite-DX-style.
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
