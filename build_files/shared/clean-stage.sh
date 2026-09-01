#!/usr/bin/bash
# Final cleanup before bootc lint + image build completion.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

# Restore the pristine dnf.conf (build.sh raises the dnf timeout for the stage).
# /tmp is tmpfs in this RUN, so the mv cannot rename -- but its cross-fs
# fallback still replaces the destination inode instead of truncating it
# (measured in-container on coreutils 9.10, 2026-09-01): safe class per
# conventions.md § Writing base-image files, no rewrite_fresh_inode needed.
if [ -f /tmp/dnf.conf.orig ]; then
    mv /tmp/dnf.conf.orig /etc/dnf/dnf.conf
fi

# NO `dnf5 versionlock clear` here. Bazzite pins 21 packages with
# `versionlock add` (upstream Containerfile:152,671): the whole kernel stack,
# the six Valve-patched mesa packages, bluez*, wireplumber*, Xwayland and
# NetworkManager*. Clearing them shipped a 31 B `packages = []` where the base
# carries 4207 B (MEASURED 2026-09-01), so any dnf5 transaction on the host or
# in an image layered on top of ours can pull an unpatched mesa or a kernel
# that no longer matches its modules. The line came from aurora's clean-stage,
# which pins nothing and has nothing to lose by it.
# check-image-integrity.sh section 9 holds the invariant on the cold bytes.

# Drop libdnf5's build-time state (pattern from aurora cf4bc197, PR #2580).
# Every file under this directory changes on every build -- timestamps,
# package versions, the transaction history dnf5 writes -- so the libdnf5
# package's chunk is unique per build and every `bootc upgrade` re-downloads
# it (~600 KB: nevras.toml 89 KB, packages.toml 66 KB, transaction_history
# .sqlite 434 KB, MEASURED 2026-09-01 on localhost/bazzite-mx:preflight).
# `dnf5 history` is not the tool for an atomic image -- the build log is --
# and deleting the sqlite here removes it from the torn-writeback surface
# entirely: build.sh step 4 no longer vacuums it and the cold check asserts
# the directory stays empty instead of probing the database.
rm -rf /usr/lib/sysimage/libdnf5/*

# Prevent Fedora flatpak repos from being added (idempotent, safe if absent)
if [ -f /usr/lib/systemd/system/flatpak-add-fedora-repos.service ]; then
    systemctl mask flatpak-add-fedora-repos.service || true
    rm -f /usr/lib/systemd/system/flatpak-add-fedora-repos.service
fi

# terra-mesa.repo is the one third-party repo the base ships with a file-level
# enabled=1: upstream disables it through /etc/dnf/repos.override.d/
# 99-config_manager.repo instead (bazzite Containerfile:126, the `setopt` idiom
# of gotcha #2), while terra-extras.repo it seds. The effective state is the
# same today, but one dropped override line makes a Terra repo fully live on
# every deployed host, with a green build and a green cold check -- neither
# validator reads repos.override.d. Both files are registered in
# third-party-repos.list now, and this sed makes the file-level invariant they
# enforce true. `sed -i` renames onto a fresh inode, so it is writeback-safe
# (conventions.md, Writing base-image files).
TERRA_MESA=/etc/yum.repos.d/terra-mesa.repo
if [ -f "$TERRA_MESA" ]; then
    sed -i 's/^enabled=1/enabled=0/g' "$TERRA_MESA"
fi
# An absent file is not silently tolerated: it is a non-optional entry of
# third-party-repos.list, so validate-repos.sh below fails on it by name.

# Selective /var cleanup (preserve cache and log: both are cache mounts
# in the final RUN, so they are mountpoints rm cannot remove)
find /var/* -maxdepth 0 -type d ! -name cache ! -name log -exec rm -fr {} \;
# No `|| true` on this rm, deliberately, where bazzite's finalize and aurora's
# clean-stage both carry one: `rm -rf` on an absent path already exits 0, so
# the only failures left are the ones worth aborting on (a permission error, a
# live mount), and swallowing them is how a half-cleaned stage ships.
rm -rf /tmp/*
# 1777, not mkdir's default 0755: /var/tmp is world-writable and sticky in
# every base image, and the find above deletes it. The preflight image shipped
# it at 755 against the base's 1777 (MEASURED 2026-09-01) -- systemd-tmpfiles
# repairs it on a booted host, which is exactly what made the regression
# invisible. Idiom from bazzite build_files/finalize:9-10.
mkdir -p /var/tmp
chmod 1777 /var/tmp

# Runtime-only directories must be empty in the committed image (bootc lint,
# fatal in the Containerfile): buildah mounts no tmpfs on /run, so dnf and
# friends leave residue there; /boot carries base-image leftovers (extlinux).
# The buildah markers stay — deleting a live mount fails the build (pattern
# from aurora clean-stage.sh, aa7471f6).
find /run -mindepth 1 \
  ! -path '/run/systemd' \
  ! -path '/run/systemd/resolve' \
  ! -path '/run/systemd/resolve/stub-resolv.conf' \
  ! -path '/run/.containerenv' \
  ! -path '/run/secrets' \
  ! -path '/run/secrets/*' \
  ! -path '/run/kmods' \
  ! -path '/run/kmods/*' \
  -delete
find /boot -mindepth 1 -delete

echo "::endgroup::"
