#!/usr/bin/env bash
# Our recipe file imported once, every recipe reachable exactly once, the
# overridden base recipe cut out with the rest intact, and the helpers behind
# the recipes on fixtures. What needs a booted host is proven there.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(realpath "$0")")/lib.sh"

CTX=$(dirname "$(realpath "$0")")/../..
JUST_DIR=/usr/share/ublue-os/just
MASTER=/usr/share/ublue-os/justfile
OURS=$JUST_DIR/95-bazzite-mx.just
SNAPSHOT=$BUILD_STATE/just.base.summary
OUR_RECIPES="install-jetbrains-toolbox migrate setup-dev setup-msi setup-ntfsplus setup-panels verify-host"

if cmp -s "$CTX/system_files$OURS" "$OURS"; then
    echo "OK: $OURS is the vendored copy"
else
    echo "FAIL: $OURS missing or not the vendored copy"
fi
if [ "$(recipe_set "$OURS" | tr '\n' ' ')" = "$OUR_RECIPES " ]; then
    echo "OK: $OURS defines exactly: $OUR_RECIPES"
else
    echo "FAIL: $OURS defines: $(recipe_set "$OURS" | tr '\n' ' ')"
fi
if [ "$(grep -c "^import \"$OURS\"$" "$MASTER")" -eq 1 ]; then
    echo "OK: $MASTER imports $OURS once"
else
    echo "FAIL: $MASTER imports $OURS $(grep -c "^import \"$OURS\"$" "$MASTER") times"
fi
master_set=$(recipe_set "$MASTER")
missing=""
for r in $OUR_RECIPES; do
    grep -qx "$r" <<< "$master_set" || missing="$missing $r"
done
if [ -z "$missing" ]; then
    echo "OK: ujust exposes every recipe of ours ($(wc -l <<< "$master_set") recipes in all)"
else
    echo "FAIL: ujust does not expose:$missing"
fi
dups=$(for f in "$JUST_DIR"/*.just; do recipe_set "$f"; done | sort | uniq -d)
if [ -z "$dups" ]; then
    echo "OK: no recipe defined in two files"
else
    echo "FAIL: recipes defined twice: $(tr '\n' ' ' <<< "$dups")"
fi
if just --justfile "$MASTER" --list > /dev/null 2>&1; then
    echo "OK: just --list works on the master justfile"
else
    echo "FAIL: just --list: $(just --justfile "$MASTER" --list 2>&1 | head -n2)"
fi

# The base's recipe is gone from its file and ours is what ujust runs.
APPS=$JUST_DIR/82-bazzite-apps.just
if ! grep -q '^install-jetbrains-toolbox' "$APPS" && ! grep -q 'brew install --cask jetbrains-toolbox' "$APPS"; then
    echo "OK: the base's install-jetbrains-toolbox is cut out of $APPS"
else
    echo "FAIL: $APPS still carries install-jetbrains-toolbox"
fi
recorded=$(grep '^82-bazzite-apps.just: ' "$SNAPSHOT" | sed 's/^[^:]*: //' | tr ' ' '\n' | sed '/^$/d' | grep -vx install-jetbrains-toolbox | sort)
if [ -n "$recorded" ] && [ "$(recipe_set "$APPS")" = "$recorded" ]; then
    echo "OK: $APPS keeps the base's other $(wc -l <<< "$recorded") recipes"
else
    echo "FAIL: $APPS recipes: $(recipe_set "$APPS" | tr '\n' ' ') vs recorded $(tr '\n' ' ' <<< "$recorded")"
fi
shown=$(just --justfile "$MASTER" --show install-jetbrains-toolbox 2>&1 || true)
if grep -q 'bazzite-mx-jetbrains-toolbox' <<< "$shown"; then
    echo "OK: ujust install-jetbrains-toolbox is our recipe"
else
    echo "FAIL: ujust --show install-jetbrains-toolbox: $(head -n3 <<< "$shown" | tr '\n' ' ')"
fi
for f in 84-bazzite-virt.just 82-bazzite-sunshine.just; do
    recorded=$(grep "^$f: " "$SNAPSHOT" | sed 's/^[^:]*: //' | tr ' ' '\n' | sed '/^$/d' | sort)
    if [ -n "$recorded" ] && [ "$(recipe_set "$JUST_DIR/$f")" = "$recorded" ] && cmp -s "$CTX/system_files$JUST_DIR/$f" "$JUST_DIR/$f"; then
        echo "OK: $f is ours and holds what the base's held ($(tr '\n' ' ' <<< "$recorded"))"
    else
        echo "FAIL: $f: ours $(recipe_set "$JUST_DIR/$f" | tr '\n' ' ') vs base $(tr '\n' ' ' <<< "$recorded")"
    fi
done

# Formatting, and the help branch of every recipe of ours.
for f in "$CTX"/system_files/usr/share/ublue-os/just/*.just; do
    check_just_fmt "$f"
done
for r in $OUR_RECIPES; do
    check_recipe_help "$MASTER" "$r"
done

# The helpers behind the recipes.
for h in bazzite-mx-verify-host bazzite-mx-migrate bazzite-mx-jetbrains-toolbox bazzite-mx-ntfsplus-setup; do
    if [ -x "/usr/libexec/$h" ] && [ "$(stat -c %a "/usr/libexec/$h")" = 755 ] && bash -n "/usr/libexec/$h"; then
        echo "OK: /usr/libexec/$h executable (755), parses"
    else
        echo "FAIL: /usr/libexec/$h missing, wrong mode or does not parse"
    fi
done
out=$(/usr/libexec/bazzite-mx-migrate --self-test 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && grep -q '^self-test ok' <<< "$out"; then
    echo "OK: migrate self-test: $(tail -n1 <<< "$out")"
else
    echo "FAIL: migrate self-test (exit $rc): $(tail -n3 <<< "$out" | tr '\n' ' ')"
fi
out=$(bash "$CTX/build_files/70-justfile.sh" --self-test 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && grep -q '^self-test ok' <<< "$out"; then
    echo "OK: 70-justfile.sh self-test: $(tail -n1 <<< "$out")"
else
    echo "FAIL: 70-justfile.sh self-test (exit $rc): $(tail -n3 <<< "$out" | tr '\n' ' ')"
fi

# verify-host on a fixture of a migrated MSI host: every check OK, and the
# file setup-msi writes is not read as residue.
work=$(mktemp -d)
fx=$work/ok
mkdir -p "$fx/cmd" "$fx/etc/containers/registries.d" "$fx/etc/pki/containers" "$fx/etc/modprobe.d" "$fx/etc/modules-load.d" "$fx/usr/share/ublue-os" "$fx/sys/class/dmi/id" "$fx/proc"
cp /usr/share/ublue-os/image-info.json "$fx/usr/share/ublue-os/"
image=$(jq -r '."image-name"' /usr/share/ublue-os/image-info.json)
cp /etc/containers/policy.json "$fx/etc/containers/"
cp /etc/containers/registries.d/matrixdj96.yaml "$fx/etc/containers/registries.d/"
cp /etc/pki/containers/matrixdj96.pub "$fx/etc/pki/containers/"
printf 'Micro-Star International Co., Ltd.\n' > "$fx/sys/class/dmi/id/sys_vendor"
printf 'msi_ec 16384 0 - Live 0x0\nacpi_ec 12288 0 - Live 0x0\nnvidia 1000 0 - Live 0x0\n' > "$fx/proc/modules"
printf 'msi-ec\nacpi_ec\n' > "$fx/etc/modules-load.d/bazzite-mx-msi.conf"
printf 'UUID=1 / btrfs subvol=root 0 0\nUUID=2 /mnt/win ntfs3 defaults,nofail 0 0\n' > "$fx/etc/fstab"
printf '/mnt/win ntfs3\n' > "$fx/cmd/mounts"
printf 'nodev\tbtrfs\n\tntfs3\n' > "$fx/proc/filesystems"
printf 'root=UUID=1 rw\n' > "$fx/cmd/kargs"
printf 'org.kde.okular\n' > "$fx/cmd/flatpaks"
if [[ $image == *nvidia* ]]; then
    printf '01:00.0 0300: 10de:2c05 (rev a1)\n' > "$fx/cmd/lspci-nvidia"
else
    : > "$fx/cmd/lspci-nvidia"
fi
printf '{"status":{"staged":null,"booted":{"incompatible":false,"pinned":false,"image":{"image":{"image":"ghcr.io/matrixdj96/%s:stable"}}}}}\n' "$image" > "$fx/cmd/bootc-status.json"
printf '{"deployments":[{"booted":true,"staged":false,"container-image-reference":"ostree-image-signed:docker://ghcr.io/matrixdj96/%s:stable","packages":[],"requested-local-packages":[],"requested-base-removals":[],"requested-modules":null,"regenerate-initramfs":false,"pinned":false,"version":"44.20260903"}]}\n' "$image" > "$fx/cmd/rpm-ostree-status.json"
out=$(FIXTURE=$fx /usr/libexec/bazzite-mx-verify-host 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && ! grep -q '^FAIL:' <<< "$out" && [ "$(grep -c '^OK:' <<< "$out")" -ge 14 ] && grep -q '^OK: no modules-load file names msi-ec' <<< "$out"; then
    echo "OK: verify-host passes on the migrated fixture ($(grep -c '^OK:' <<< "$out") OK lines, setup-msi's file not residue)"
else
    echo "FAIL: verify-host on the migrated fixture (exit $rc): $(grep -E '^(FAIL|ERROR)' <<< "$out" | tr '\n' ' ')"
fi
# Known-bad: a host before the migration, with every defect at once. Each one
# must be named on its own line.
bad=$work/bad
cp -a "$fx/." "$bad/"
printf '{"status":{"staged":null,"booted":{"incompatible":true,"pinned":false,"image":null}}}\n' > "$bad/cmd/bootc-status.json"
printf '{"deployments":[{"booted":true,"staged":false,"container-image-reference":"ostree-unverified-registry:ghcr.io/matrixdj96/%s:44.20260831","packages":[],"requested-packages":["1password"],"requested-local-packages":["teams-for-linux"],"regenerate-initramfs":true,"initramfs-args":["--hostonly"],"pinned":false,"version":"44.20260831"}]}\n' "$image" > "$bad/cmd/rpm-ostree-status.json"
jq 'del(.transports.docker["ghcr.io/matrixdj96"])' "$fx/etc/containers/policy.json" > "$bad/etc/containers/policy.json"
printf 'UUID=2 /mnt/win ntfs defaults,nofail 0 0\n' > "$bad/etc/fstab"
printf 'nvidia 1000 0 - Live 0x0\n' > "$bad/proc/modules"
printf 'blacklist ntfsplus\n' > "$bad/etc/modprobe.d/ntfsplus.conf"
printf 'msi-ec\n' > "$bad/etc/modules-load.d/msi-ec.conf"
printf 'org.mozilla.firefox\n' > "$bad/cmd/flatpaks"
out=$(FIXTURE=$bad /usr/libexec/bazzite-mx-verify-host 2>&1) && rc=0 || rc=$?
expected_fails='bootc status reports|origin is not ostree-image-signed|rpm-ostree mutations in the origin: 1password teams-for-linux|initramfs is regenerated locally|policy.json has no sigstoreSigned scope|MSI host: msi_ec not loaded|MSI host: acpi_ec not loaded|fstab: /mnt/win uses type ntfs without the ntfsplus opt-in|ntfsplus residue: /etc/modprobe.d/ntfsplus.conf|MSI residue: /etc/modules-load.d/msi-ec.conf'
n=$(grep -E '^FAIL:' <<< "$out" | grep -cE "$expected_fails" || true)
if [ "$rc" -eq 1 ] && [ "$n" -eq 10 ] && grep -q '^INFO: the Firefox Flatpak is still installed' <<< "$out"; then
    echo "OK: verify-host names every defect of the unmigrated fixture (10 FAIL lines, exit 1, Firefox Flatpak reported)"
else
    echo "FAIL: verify-host on the unmigrated fixture: exit $rc, $n of 10 expected FAIL lines: $(grep -E '^(FAIL|INFO|ERROR)' <<< "$out" | tr '\n' ' ')"
fi
# Opted into NTFSPLUS: rows on ntfs, mounted as ntfs, driver registered.
# Known-bad: a row left on ntfs3, and the driver not registered.
optin=$work/optin
cp -a "$fx/." "$optin/"
printf '# opt-in\n' > "$optin/etc/modprobe.d/bazzite-mx-ntfsplus.conf"
printf 'UUID=1 / btrfs subvol=root 0 0\nUUID=2 /mnt/win ntfs defaults,nofail 0 0\n' > "$optin/etc/fstab"
printf '/mnt/win ntfs\n' > "$optin/cmd/mounts"
printf 'nodev\tbtrfs\n\tntfs3\n\tntfs\n' > "$optin/proc/filesystems"
out=$(FIXTURE=$optin /usr/libexec/bazzite-mx-verify-host 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && ! grep -q '^FAIL:' <<< "$out" && grep -q '^OK: ntfsplus opt-in active' <<< "$out" && grep -q '^OK: fstab: /mnt/win is ntfs and mounted with ntfs' <<< "$out"; then
    echo "OK: verify-host passes on the ntfsplus opt-in fixture (ntfs rows expected, opt-in file not residue)"
else
    echo "FAIL: verify-host on the opt-in fixture (exit $rc): $(grep -E '^(FAIL|ERROR)' <<< "$out" | tr '\n' ' ')"
fi
printf 'UUID=1 / btrfs subvol=root 0 0\nUUID=2 /mnt/win ntfs3 defaults,nofail 0 0\n' > "$optin/etc/fstab"
printf 'nodev\tbtrfs\n\tntfs3\n' > "$optin/proc/filesystems"
out=$(FIXTURE=$optin /usr/libexec/bazzite-mx-verify-host 2>&1 || true)
if grep -q '^FAIL: fstab: /mnt/win uses type ntfs3 while the ntfsplus opt-in is active' <<< "$out" && grep -q '^INFO: the ntfs driver is not registered yet' <<< "$out"; then
    echo "OK: verify-host names an ntfs3 row under the opt-in, reports an unloaded driver as INFO"
else
    echo "FAIL: verify-host under the opt-in with an ntfs3 row: $(grep -E '^(FAIL|OK).*ntfs' <<< "$out" | tr '\n' ' ')"
fi

# A flavour that does not match the GPU is a defect in both directions.
mkdir -p "$work/gpu" && cp -a "$fx/." "$work/gpu/"
if [[ $image == *nvidia* ]]; then
    : > "$work/gpu/cmd/lspci-nvidia"
    want='no NVIDIA GPU on the bus but the image is'
else
    printf '01:00.0 0300: 10de:2c05 (rev a1)\n' > "$work/gpu/cmd/lspci-nvidia"
    want='NVIDIA GPU present but the image is'
fi
out=$(FIXTURE=$work/gpu /usr/libexec/bazzite-mx-verify-host 2>&1 || true)
if grep -q "^FAIL: $want" <<< "$out"; then
    echo "OK: verify-host refuses a flavour that does not match the GPU"
else
    echo "FAIL: verify-host GPU/flavour check: $(grep -E '^(FAIL|OK).*(GPU|nvidia)' <<< "$out" | tr '\n' ' ')"
fi

# The Toolbox installer on a file:// feed with a synthetic tarball.
tb=$work/toolbox
mkdir -p "$tb/home" "$tb/jetbrains-toolbox-9.9.9/bin"
printf '#!/bin/sh\necho toolbox\n' > "$tb/jetbrains-toolbox-9.9.9/bin/jetbrains-toolbox"
chmod 755 "$tb/jetbrains-toolbox-9.9.9/bin/jetbrains-toolbox"
printf '9.9.9\n' > "$tb/jetbrains-toolbox-9.9.9/bin/build.txt"
tar czf "$tb/jetbrains-toolbox-9.9.9.tar.gz" -C "$tb" jetbrains-toolbox-9.9.9
printf '%s *jetbrains-toolbox-9.9.9.tar.gz\n' "$(sha256sum "$tb/jetbrains-toolbox-9.9.9.tar.gz" | cut -d' ' -f1)" > "$tb/good.sha256"
printf '%064d *jetbrains-toolbox-9.9.9.tar.gz\n' 0 > "$tb/wrong.sha256"
feed() {
    printf '{"TBA":[{"build":"9.9.9","downloads":{"linux":{"link":"file://%s/jetbrains-toolbox-9.9.9.tar.gz","checksumLink":"file://%s/%s"}}}]}\n' "$tb" "$tb" "$1"
}
feed good.sha256 > "$tb/feed-good.json"
feed wrong.sha256 > "$tb/feed-wrong.json"
run_toolbox() {
    HOME=$tb/home XDG_DATA_HOME='' XDG_CACHE_HOME='' NO_LAUNCH=1 CURL_PROTO='=https,file' FEED_URL="file://$tb/$1" /usr/libexec/bazzite-mx-jetbrains-toolbox "$2"
}
out=$(run_toolbox feed-good.json latest 2>&1 || true)
if grep -q '^build 9.9.9$' <<< "$out"; then
    echo "OK: toolbox latest reads the feed"
else
    echo "FAIL: toolbox latest: $(head -n2 <<< "$out" | tr '\n' ' ')"
fi
if out=$(run_toolbox feed-wrong.json install 2>&1); then
    echo "FAIL: toolbox installer accepted a wrong sha256"
elif grep -q 'sha256 mismatch' <<< "$out" && [ ! -e "$tb/home/.local/share/JetBrains/ToolboxApp" ] && [ ! -e "$tb/home/.cache/bazzite-mx/jetbrains-toolbox/jetbrains-toolbox-9.9.9.tar.gz" ]; then
    echo "OK: toolbox installer refuses a wrong sha256, installs nothing, drops the download"
else
    echo "FAIL: toolbox installer on a wrong sha256: $(tail -n1 <<< "$out"); $(find "$tb/home" -type f | tr '\n' ' ')"
fi
if out=$(run_toolbox feed-good.json install 2>&1) && [ -x "$tb/home/.local/share/JetBrains/ToolboxApp/bin/jetbrains-toolbox" ] \
    && [ "$(cat "$tb/home/.local/share/JetBrains/ToolboxApp/bin/build.txt")" = 9.9.9 ]; then
    echo "OK: toolbox installer unpacks the verified build ($(tail -n1 <<< "$out"))"
else
    echo "FAIL: toolbox installer on the good feed: $(tail -n2 <<< "$out" | tr '\n' ' ')"
fi
out=$(run_toolbox feed-good.json status 2>&1 || true)
if grep -q '^installed: build 9.9.9 at ' <<< "$out"; then
    echo "OK: toolbox status reports the installed build"
else
    echo "FAIL: toolbox status: $(head -n1 <<< "$out")"
fi
out=$(run_toolbox feed-good.json install 2>&1 || true)
if grep -q 'already installed' <<< "$out"; then
    echo "OK: toolbox installer is idempotent on the same build"
else
    echo "FAIL: toolbox second install: $(tail -n1 <<< "$out")"
fi
# A Toolbox unpacked at the same path by something else (an earlier recipe, a
# hand install) carries upstream's bin/build.txt and nothing of ours: status
# reports it and install leaves it alone.
rm -rf "$tb/home/.local" "$tb/home/.cache"
mkdir -p "$tb/home/.local/share/JetBrains/ToolboxApp"
cp -a "$tb/jetbrains-toolbox-9.9.9/bin" "$tb/home/.local/share/JetBrains/ToolboxApp/"
out=$(run_toolbox feed-good.json status 2>&1 || true)
if grep -q '^installed: build 9.9.9 at ' <<< "$out"; then
    echo "OK: toolbox status reads the build of a Toolbox it did not unpack (bin/build.txt)"
else
    echo "FAIL: toolbox status on a foreign Toolbox: $(head -n1 <<< "$out")"
fi
out=$(run_toolbox feed-good.json install 2>&1 || true)
if grep -q 'already installed' <<< "$out" && [ ! -e "$tb/home/.cache/bazzite-mx/jetbrains-toolbox/jetbrains-toolbox-9.9.9.tar.gz" ]; then
    echo "OK: toolbox installer leaves a foreign Toolbox of the same build alone"
else
    echo "FAIL: toolbox install over a foreign Toolbox of the same build: $(tail -n1 <<< "$out")"
fi
# Known-bad: the binary is there but upstream's bin/build.txt is not.
rm -rf "$tb/home/.local" "$tb/home/.cache" "$tb/jetbrains-toolbox-9.9.9/bin/build.txt"
tar czf "$tb/jetbrains-toolbox-9.9.9.tar.gz" -C "$tb" jetbrains-toolbox-9.9.9
printf '%s *jetbrains-toolbox-9.9.9.tar.gz\n' "$(sha256sum "$tb/jetbrains-toolbox-9.9.9.tar.gz" | cut -d' ' -f1)" > "$tb/good.sha256"
if out=$(run_toolbox feed-good.json install 2>&1); then
    echo "FAIL: toolbox installer accepted a tarball without bin/build.txt"
elif grep -q 'bin/build.txt missing' <<< "$out" && [ ! -e "$tb/home/.local/share/JetBrains/ToolboxApp" ]; then
    echo "OK: toolbox installer refuses a tarball without bin/build.txt"
else
    echo "FAIL: toolbox installer on a tarball without build.txt: $(tail -n1 <<< "$out")"
fi
# Known-bad: the checksum is right but bin/jetbrains-toolbox is missing.
rm -rf "$tb/home/.local" "$tb/home/.cache" "$tb/jetbrains-toolbox-9.9.9/bin"
mkdir -p "$tb/jetbrains-toolbox-9.9.9/lib"
tar czf "$tb/jetbrains-toolbox-9.9.9.tar.gz" -C "$tb" jetbrains-toolbox-9.9.9
printf '%s *jetbrains-toolbox-9.9.9.tar.gz\n' "$(sha256sum "$tb/jetbrains-toolbox-9.9.9.tar.gz" | cut -d' ' -f1)" > "$tb/good.sha256"
if out=$(run_toolbox feed-good.json install 2>&1); then
    echo "FAIL: toolbox installer accepted a tarball without the binary"
elif grep -q 'bin/jetbrains-toolbox missing' <<< "$out" && [ ! -e "$tb/home/.local/share/JetBrains/ToolboxApp" ]; then
    echo "OK: toolbox installer refuses a tarball without bin/jetbrains-toolbox"
else
    echo "FAIL: toolbox installer on a tarball without the binary: $(tail -n1 <<< "$out")"
fi
rm -rf "$work"

# setup-dev's inputs.
if [ -x /usr/bin/mise ] && [ -s /etc/skel/.config/mise/config.toml ]; then
    echo "OK: mise and the skel config setup-dev seeds are in the image"
else
    echo "FAIL: /usr/bin/mise or /etc/skel/.config/mise/config.toml missing"
fi
