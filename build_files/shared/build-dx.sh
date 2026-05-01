#!/usr/bin/bash
# DX overlay entry point. Always invoked by build.sh because bazzite-mx
# is a DX-tier image by definition.
# Style: ported from ublue-os/aurora build-dx.sh + 00-dx.sh structure.
#
# Sequence:
#   1. Copy DX-specific system_files
#   2. IP forwarding for Docker (sysctl + iptable_nat module)
#   3. Branding "Developer Experience" in kcm-about (best-effort: only if
#      the upstream KCM file exists; Bazzite path may differ from Aurora)
#   4. Run all numbered DX scripts (build_files/dx/*.sh) in lexical order

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

CTX="${CTX:-/ctx}"

# 1. Copy DX-specific system_files (if present)
if [ -d "$CTX/system_files/dx" ]; then
    rsync -rvKl "$CTX/system_files/dx/" /
fi

# 2. IP forwarding for Docker (in stile Aurora build-dx.sh)
cat > /etc/sysctl.d/90-bazzite-mx-dx-forwarding.conf <<'EOF'
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1
EOF
mkdir -p /etc/modules-load.d
echo iptable_nat > /etc/modules-load.d/90-bazzite-mx-dx.conf

# 3. Branding "Developer Experience" in kcm-about
KCM=/usr/share/kcm-about-distro/kcm-about-distrorc
if [ -f "$KCM" ]; then
    if ! grep -q '^Variant=' "$KCM"; then
        echo 'Variant=Developer Experience' >> "$KCM"
    fi
fi

# 4. Run all numbered DX scripts (build_files/dx/*.sh) in lexical order
DX="$CTX/build_files/dx"
if compgen -G "$DX/[0-9]*-*.sh" > /dev/null; then
    for s in $(ls -1v "$DX"/[0-9]*-*.sh); do
        echo "::group::Running $(basename "$s")"
        bash "$s"
        echo "::endgroup::"
    done
fi

echo "::endgroup::"
