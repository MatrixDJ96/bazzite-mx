# Wins over `bazzite-dx` upstream

bazzite-mx is a personal fork that aims to be **strictly better** than
`ublue-os/bazzite-dx` upstream by adopting Aurora-DX's build patterns and
fixing concrete issues. **2 wins** as of the container-runtime commit;
wins accumulate as each domain commit lands.

## 1. Strict repo isolation via `validate-repos.sh`

**Upstream**: no equivalent. bazzite-dx ships its image and trusts that
the install order leaves no third-party repo enabled.

**Us**: `build_files/shared/validate-repos.sh` runs at the end of every
build. Hard-fails if any file in the explicit `OTHER_REPOS` list (or any
`_copr:*` / `_copr_*` / `rpmfusion-*`) has `^enabled=1`. Plus an
informational catch-all sweep that lists every other `.repo` file so a
new third-party landing without registration is visible in PR review.

**Why it matters**: a deployed `bootc upgrade` on the user's machine
re-reads `/etc/yum.repos.d/`. A leftover `enabled=1` on docker-ce.repo
would silently pull docker package updates from docker.com on every
upgrade, breaking the reproducibility we promise.

## 2. `docker-ce.repo` vendored in git

**Upstream**: `dnf5 config-manager addrepo --from-repofile=https://download.docker.com/...`
fetched at build time, every time. No auditable diff in git if Docker
upstream changes the .repo file format / baseurl / gpgkey.

**Us**: `system_files/etc/yum.repos.d/docker-ce.repo` committed. Single
section `[docker-ce]` with `enabled=0`, `gpgcheck=1`,
`gpgkey=https://download.docker.com/linux/fedora/gpg`. Any future
upstream change requires a deliberate edit of the vendored file in a PR.

**Why it matters**: supply-chain auditability. Reviewer of a future PR
can see exactly what the trust anchor for Docker installs is, without
diffing against external state.

## How to extend this list

When adding a new Phase, deliberately ask: **does this give us an edge
over upstream `bazzite-dx`?** If yes, document it here with:
- Commit hash that introduces it.
- The upstream behaviour we're improving on (with `file:line` reference).
- Our solution (with `file:line` reference).
- Why it matters for an end user.

Avoid soft wins (formatting, naming, "I prefer X"). Real wins:
- A bug we fix that they ship broken.
- A package they're missing that's clearly within scope.
- A supply-chain hardening they don't have.
- A maintenance reduction (zero-cost auto-update of keys, etc.).
