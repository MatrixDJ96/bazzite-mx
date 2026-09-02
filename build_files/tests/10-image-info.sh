#!/usr/bin/env bash
# Smoke test of 10-image-info.sh: the image names itself, and image-info.json,
# os-release and the KDE About page agree.
#
# Usage: run by tests/run.sh inside the image (offline, on the cleaned tree).
# Output: one `OK: <what>` or `FAIL: <what>` line per check, on stdout.
# Exit status: 0 on any outcome; the runner judges the FAIL lines.
set -euo pipefail

IMAGE_INFO=/usr/share/ublue-os/image-info.json
OS_RELEASE=/usr/lib/os-release
KDE_ABOUT_PAGE=/etc/xdg/kcm-about-distrorc

name=$(jq -r '."image-name"' "$IMAGE_INFO")
version=$(jq -r '.version' "$IMAGE_INFO")

check_image_name() {
    local wanted='."image-name" | test("^bazzite-mx(-nvidia(-open)?)?$")'

    if jq -e "$wanted" "$IMAGE_INFO" > /dev/null; then
        echo "OK: image-name is $name"
    else
        echo "FAIL: image-name is $name"
    fi
}

check_image_ref() {
    local fields
    local wanted='."image-vendor" == "matrixdj96"
        and (."image-ref" | startswith("ostree-image-signed:docker://ghcr.io/matrixdj96/"))'

    if jq -e "$wanted" "$IMAGE_INFO" > /dev/null; then
        echo "OK: image-ref points at ghcr.io/matrixdj96 over the signed transport"
    else
        fields=$(jq -c '{"image-vendor", "image-ref"}' "$IMAGE_INFO")
        echo "FAIL: image-ref or image-vendor: $fields"
    fi
}

# The version is a release tag or `<base>.dev`, the base version is kept,
# and the pretty string carries the version.
check_version_fields() {
    local fields
    local wanted='(.version | test("^[0-9]+\\.[0-9]{8}"))
        and ."base-version" != null
        and (."version-pretty" | contains($v))'

    if jq -e --arg v "$version" "$wanted" "$IMAGE_INFO" > /dev/null; then
        echo "OK: version $version, base $(jq -r '."base-version"' "$IMAGE_INFO")"
    else
        fields=$(jq -c '{version, "base-version", "version-pretty"}' "$IMAGE_INFO")
        echo "FAIL: version fields: $fields"
    fi
}

check_os_release() {
    if grep -qx "VARIANT_ID=$name" "$OS_RELEASE" \
        && grep -qx "IMAGE_ID=\"$name-$version\"" "$OS_RELEASE"; then
        echo "OK: os-release VARIANT_ID and IMAGE_ID match"
    else
        echo "FAIL: os-release: $(grep -E '^(VARIANT_ID|IMAGE_ID)=' "$OS_RELEASE" | tr '\n' ' ')"
    fi
}

check_kde_about_page() {
    local fields

    if grep -q '^Variant=MX' "$KDE_ABOUT_PAGE" \
        && grep -q "^Website=https://github.com/matrixdj96/$name$" "$KDE_ABOUT_PAGE"; then
        echo "OK: KDE About page names MX"
    else
        fields=$(grep -E '^(Variant|Website)=' "$KDE_ABOUT_PAGE" | tr '\n' ' ')
        echo "FAIL: kcm-about-distrorc: $fields"
    fi
}

check_image_name
check_image_ref
check_version_fields
check_os_release
check_kde_about_page
