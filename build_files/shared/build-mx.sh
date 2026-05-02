#!/usr/bin/bash
# MX build entry point. Always invoked by build.sh: bazzite-mx is a
# single-flavour distribution and every build step here is unconditional.
# Style: ported from ublue-os/aurora build-dx.sh + 00-dx.sh structure
# (the original Aurora `dx` overlay name is preserved as historical
# attribution; semantically MX = "always-on Aurora-DX-style overlay
# applied directly on top of Bazzite base").
#
# Sequence:
#   1. IP forwarding for Docker (sysctl + iptable_nat module)
#   2. Run all numbered MX build scripts (build_files/mx/*.sh) in
#      lexical order. Branding (image-info.json + os-release +
#      kcm-about-distrorc) lives inside the first numbered script
#      (00-image-info.sh) and is part of that ordering.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

CTX="${CTX:-/ctx}"

# 1. IP forwarding for Docker
cat > /etc/sysctl.d/90-bazzite-mx-forwarding.conf <<'EOF'
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1
EOF
mkdir -p /etc/modules-load.d
echo iptable_nat > /etc/modules-load.d/90-bazzite-mx.conf

# 2. Run all numbered MX scripts (build_files/mx/*.sh) in lexical order
MX="$CTX/build_files/mx"
mapfile -t MX_SCRIPTS < <(find "$MX" -maxdepth 1 -type f -name '[0-9]*-*.sh' | sort -V)
for s in "${MX_SCRIPTS[@]}"; do
    echo "::group::Running $(basename "$s")"
    bash "$s"
    echo "::endgroup::"
done

echo "::endgroup::"
