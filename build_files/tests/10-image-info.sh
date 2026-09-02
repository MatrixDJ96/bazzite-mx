#!/usr/bin/env bash
# The image names itself: json, os-release and the KDE About page agree.
set -euo pipefail

INFO=/usr/share/ublue-os/image-info.json
name=$(jq -r '."image-name"' "$INFO")
version=$(jq -r '.version' "$INFO")

if jq -e '."image-name" | test("^bazzite-mx(-nvidia(-open)?)?$")' "$INFO" > /dev/null; then
    echo "OK: image-name is $name"
else
    echo "FAIL: image-name is $name"
fi
if jq -e '."image-vendor" == "matrixdj96" and (."image-ref" | startswith("ostree-image-signed:docker://ghcr.io/matrixdj96/"))' "$INFO" > /dev/null; then
    echo "OK: image-ref points at ghcr.io/matrixdj96 over the signed transport"
else
    echo "FAIL: image-ref or image-vendor: $(jq -c '{"image-vendor", "image-ref"}' "$INFO")"
fi
if jq -e --arg v "$version" '(.version | test("^[0-9]+\\.[0-9]{8}")) and ."base-version" != null and (."version-pretty" | contains($v))' "$INFO" > /dev/null; then
    echo "OK: version $version, base $(jq -r '."base-version"' "$INFO")"
else
    echo "FAIL: version fields: $(jq -c '{version, "base-version", "version-pretty"}' "$INFO")"
fi
if grep -qx "VARIANT_ID=$name" /usr/lib/os-release && grep -qx "IMAGE_ID=\"$name-$version\"" /usr/lib/os-release; then
    echo "OK: os-release VARIANT_ID and IMAGE_ID match"
else
    echo "FAIL: os-release: $(grep -E '^(VARIANT_ID|IMAGE_ID)=' /usr/lib/os-release | tr '\n' ' ')"
fi
if grep -q '^Variant=MX' /etc/xdg/kcm-about-distrorc && grep -q "^Website=https://github.com/matrixdj96/$name$" /etc/xdg/kcm-about-distrorc; then
    echo "OK: KDE About page names MX"
else
    echo "FAIL: kcm-about-distrorc: $(grep -E '^(Variant|Website)=' /etc/xdg/kcm-about-distrorc | tr '\n' ' ')"
fi
