#!/usr/bin/bash
# MX build entry point, invoked by build.sh.
#   1. IP forwarding for Docker (sysctl + iptable_nat module)
#   2. Run all numbered MX build scripts (build_files/mx/*.sh) in
#      lexical order; branding is the first one (00-image-info.sh).

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

CTX="${CTX:-/ctx}"

# 1. IP forwarding for Docker
cat > /etc/sysctl.d/90-bazzite-mx-forwarding.conf <<'EOF'
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1
EOF
mkdir -p /etc/modules-load.d
echo iptable_nat > /etc/modules-load.d/90-bazzite-mx-nat.conf

# 2. Run the numbered MX scripts in version order (sort -V)
MX="$CTX/build_files/mx"
mapfile -t MX_SCRIPTS < <(find "$MX" -maxdepth 1 -type f -name '[0-9]*-*.sh' | sort -V)
for s in "${MX_SCRIPTS[@]}"; do
    echo "::group::Running $(basename "$s")"
    bash "$s"
    echo "::endgroup::"
done

echo "::endgroup::"
