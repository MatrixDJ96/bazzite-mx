#!/usr/bin/bash
# DX overlay entry point. Always invoked by build.sh: MX is a DX-tier
# distribution by definition.
# Style: ported from ublue-os/aurora build-dx.sh + 00-dx.sh structure.
#
# Sequence:
#   1. IP forwarding for Docker (sysctl + iptable_nat module)
#   2. Branding "Developer Experience" in kcm-about (best-effort: only if
#      the upstream KCM file exists; Bazzite path may differ from Aurora)
#   3. Run all numbered DX scripts (build_files/dx/*.sh) in lexical order

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

CTX="${CTX:-/ctx}"

# 1. IP forwarding for Docker (in stile Aurora build-dx.sh)
cat > /etc/sysctl.d/90-bazzite-mx-dx-forwarding.conf <<'EOF'
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1
EOF
mkdir -p /etc/modules-load.d
echo iptable_nat > /etc/modules-load.d/90-bazzite-mx-dx.conf

# 2. Branding "Developer Experience" in kcm-about (best-effort)
KCM=/usr/share/kcm-about-distro/kcm-about-distrorc
if [ -f "$KCM" ]; then
    if ! grep -q '^Variant=' "$KCM"; then
        echo 'Variant=Developer Experience' >> "$KCM"
    fi
fi

# 3. Run all numbered DX scripts (build_files/dx/*.sh) in lexical order
DX="$CTX/build_files/dx"
if compgen -G "$DX/[0-9]*-*.sh" > /dev/null; then
    for s in $(ls -1v "$DX"/[0-9]*-*.sh); do
        echo "::group::Running $(basename "$s")"
        bash "$s"
        echo "::endgroup::"
    done
fi

echo "::endgroup::"
