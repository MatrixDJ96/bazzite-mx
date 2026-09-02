#!/usr/bin/env bash
# Container runtime: packages, trust anchor, socket activation, the group the
# boot hook needs, and the hook on a fixture.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
# shellcheck source=../lib/log.sh
source "$CTX/build_files/lib/log.sh"
# shellcheck source=../lib/gpg.sh
source "$CTX/build_files/lib/gpg.sh"

check_pkg containerd.io docker-buildx-plugin docker-ce docker-ce-cli docker-compose-plugin \
    bcvk podman podman-compose podman-machine podman-tui
if rpm -q docker-model-plugin > /dev/null 2>&1; then
    echo "FAIL: docker-model-plugin installed (left out on purpose)"
else
    echo "OK: docker-model-plugin absent"
fi

# The shipped key is the pinned one, the .repo reads it from the file, and
# dnf5 imported it into the rpm keyring at install.
KEY=/etc/pki/rpm-gpg/RPM-GPG-KEY-docker-ce
FPR=${KEY_FPR[$KEY]}
if [ "$(key_fingerprint "$KEY")" = "$FPR" ]; then
    echo "OK: $KEY fingerprint $FPR"
else
    echo "FAIL: $KEY fingerprint $(key_fingerprint "$KEY" || true)"
fi
if (assert_key_fingerprint "$KEY" 0000000000000000000000000000000000000000) > /dev/null 2>&1; then
    echo "FAIL: assert_key_fingerprint accepted a wrong fingerprint"
else
    echo "OK: assert_key_fingerprint refuses a wrong fingerprint"
fi
if grep -q "^gpgkey=file://$KEY$" /etc/yum.repos.d/docker-ce.repo; then
    echo "OK: docker-ce.repo reads the vendored key"
else
    echo "FAIL: docker-ce.repo gpgkey line: $(grep '^gpgkey' /etc/yum.repos.d/docker-ce.repo || true)"
fi
if rpm -q gpg-pubkey --qf '%{VERSION}\n' | grep -qi '621e9f35$'; then
    echo "OK: Docker key in the rpm keyring"
else
    echo "FAIL: Docker key (…621e9f35) not in the rpm keyring"
fi

check_unit_state docker.socket enabled
check_unit_state podman.socket enabled
check_unit_state docker.service disabled "socket-activated"

kver=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n1)
if grep -qx 'iptable_nat' /usr/lib/modules-load.d/ip_tables.conf && modinfo -k "$kver" iptable_nat > /dev/null 2>&1; then
    echo "OK: iptable_nat listed in modules-load.d and present for kernel $kver"
else
    echo "FAIL: iptable_nat missing from modules-load.d or from kernel $kver"
fi

# Created by the %post, relocated out of /etc/group by clean-stage.
if grep -q '^docker:' /usr/lib/group && ! grep -q '^docker:' /etc/group; then
    echo "OK: docker group in /usr/lib/group, not in /etc/group"
else
    echo "FAIL: docker group: /usr/lib/group=$(grep '^docker:' /usr/lib/group || echo none) /etc/group=$(grep '^docker:' /etc/group || echo none)"
fi

# The fixture's /usr/lib/group is the image's, so the test follows the hook's
# own GROUPS_TARGET instead of repeating the list.
HOOK=/usr/share/ublue-os/system-setup.hooks.d/10-bazzite-mx-groups.sh
fx=$(mktemp -d)
mkdir -p "$fx/etc" "$fx/usr/lib"
printf 'root:x:0:0:root:/root:/bin/bash\nalice:x:1000:1000::/home/alice:/bin/bash\nbob:x:1001:1001::/home/bob:/bin/bash\n' > "$fx/etc/passwd"
printf 'root:x:0:\nwheel:x:10:alice\nalice:x:1000:\nbob:x:1001:\n' > "$fx/etc/group"
cp /usr/lib/group "$fx/usr/lib/group"
check_members() {
    # every group the hook summarised has alice and not bob
    local groups g
    groups=$(sed -n 's/^bazzite-mx-groups: [0-9]* wheel user(s) in //p' <<< "$1")
    [ -n "$groups" ] || return 1
    for g in $groups; do
        grep -q "^${g}:[^:]*:[^:]*:alice$" "$fx/etc/group" || return 1
    done
    ! grep -q '^docker:.*bob' "$fx/etc/group"
}
if out=$(BAZZITE_MX_GROUPS_PREFIX=$fx bash "$HOOK" 2>&1) && check_members "$out"; then
    echo "OK: hook adds the wheel user to $(sed -n 's/^bazzite-mx-groups: [0-9]* wheel user(s) in //p' <<< "$out")"
else
    echo "FAIL: hook on fixture: $out; group file: $(grep -E '^(docker|libvirt):' "$fx/etc/group" || echo none)"
fi
if out=$(BAZZITE_MX_GROUPS_PREFIX=$fx bash "$HOOK" 2>&1) && check_members "$out" && ! grep -q 'adding' <<< "$out"; then
    echo "OK: hook is idempotent on a second run"
else
    echo "FAIL: second hook run: $out"
fi
: > "$fx/usr/lib/group"
sed -i '/^\(docker\|libvirt\):/d' "$fx/etc/group"
if out=$(BAZZITE_MX_GROUPS_PREFIX=$fx bash "$HOOK" 2>&1); then
    echo "FAIL: hook exited 0 with the target groups missing from both files"
elif grep -q 'ERROR: group(s) docker' <<< "$out"; then
    echo "OK: hook reports and fails on missing groups"
else
    echo "FAIL: hook failed without naming the missing groups: $out"
fi
rm -rf "$fx"
