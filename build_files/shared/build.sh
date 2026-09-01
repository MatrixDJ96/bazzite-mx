#!/usr/bin/bash
# Top-level build orchestrator: copy system_files, run the numbered MX
# build steps, clean the stage, validate repos are all disabled.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

CTX="${CTX:-/ctx}"

# Network resilience for every dnf5 call in this stage: raise the
# per-connection timeout from the 30s default — COPR/mirror flakes are the
# most common CI build failure (pattern from Aurora upstream).
# clean-stage.sh restores the original dnf.conf.
cp /etc/dnf/dnf.conf /tmp/dnf.conf.orig
dnf5 config-manager setopt timeout=60

# 1. Copy system_files
if [ -d "$CTX/system_files" ]; then
    rsync -rvKl "$CTX/system_files/" /
fi

# 2. Run the numbered MX build scripts
"$CTX/build_files/shared/build-mx.sh"

# 3. Cleanup + repo isolation validation (build fails if any repo enabled=1)
"$CTX/build_files/shared/clean-stage.sh"
"$CTX/build_files/shared/validate-repos.sh"

# 4. Rewrite the rpmdb onto a fresh inode. The 6.17-azure kernel on runner
# image ubuntu-24.04 20260816+ loses page writeback of sqlite writes into a
# copied-up overlay file — fsync included — so the committed layer carries torn
# tail pages (shipped as release 44.20260823; proven by the diagnose-rechunk
# v5/v6 ladder, where only this rewrite survives a cold re-read). VACUUM INTO
# writes a brand-new sequential file, which survives. One database qualifies:
# the rpmdb that every dnf5 transaction writes — libdnf5's transaction history
# was the second until clean-stage.sh started deleting that directory outright.
# Runs last: every dnf5 transaction in the stage, from build-mx.sh's installs
# down to clean-stage.sh, must already have written its pages.
python3 - <<'PYEOF'
import os, sqlite3

for db in ("/usr/share/rpm/rpmdb.sqlite",):
    rebuilt = db + ".rebuilt"
    # mode=rw: connect() to a bare path CREATES a missing database, so a path
    # typo or an rpm layout change would turn this guard into a generator
    # of green empty databases. rw refuses to create and fails loudly.
    c = sqlite3.connect(f"file:{db}?mode=rw", uri=True)
    c.execute(f"VACUUM INTO '{rebuilt}'")
    c.close()
    os.replace(rebuilt, db)
    fd = os.open(db, os.O_RDWR)
    os.fsync(fd)
    os.close(fd)
    # VACUUM INTO reads through the WAL, so the vacuumed copy already carries
    # every committed page: a sidecar left beside a replaced database belongs
    # to the old one and sqlite refuses to recover from it.
    for sidecar in (db + "-wal", db + "-shm"):
        if os.path.exists(sidecar):
            os.unlink(sidecar)
    print(f"{db} rewritten onto a fresh inode")
PYEOF

# 5. Relink /usr/lib/sysimage/rpm-ostree-base-db onto the rpmdb this build
# produced. rpm-ostree keeps that directory as the "base" it diffs the
# deployment against, and a derived image inherits the base image's copy: on a
# deployed host `rpm-ostree status` and `rpm-ostree db diff` therefore describe
# plain bazzite, not bazzite-mx (MEASURED on ldesktop-zrombi 2026-09-01:
# base-db 99,942,400 B against a 149,180,416 B rpmdb, distinct inodes). A
# hardlink also drops the duplicate copy from the image
# (coreos/rpm-ostree#4554; pattern from aurora ca167c7b, itself from
# blue-build/cli b6f36bd9 -- both put it in clean-stage, which for us runs
# BEFORE step 4 mints a new inode, so it lands here instead).
#
# Unlike aurora's loop we also drop the base image's -wal/-shm: step 4 leaves
# none beside the rpmdb, and a sidecar belonging to the OLD database is exactly
# what sqlite refuses to recover from.
BASE_DB=/usr/lib/sysimage/rpm-ostree-base-db
if [ -d "$BASE_DB" ]; then
    rm -f "$BASE_DB/rpmdb.sqlite-wal" "$BASE_DB/rpmdb.sqlite-shm"
    # Hardlink, not a symlink: rpm-ostree resolves the directory itself.
    ln -f /usr/share/rpm/rpmdb.sqlite "$BASE_DB/rpmdb.sqlite"
    ls -li "$BASE_DB"
else
    echo "FAIL: $BASE_DB is missing (upstream layout changed?)"
    exit 1
fi
sync

echo "::endgroup::"
