# Wins over `bazzite-dx` upstream

bazzite-mx is a personal fork that aims to be **strictly better** than
`ublue-os/bazzite-dx` upstream by adopting Aurora-DX's build patterns and
fixing concrete issues. Cumulative wins as of 2026-05-02:

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

**Us**: `system_files/etc/yum.repos.d/docker-ce.repo` committed (commit
`650f002`). Single section `[docker-ce]` with `enabled=0`, `gpgcheck=1`,
`gpgkey=https://download.docker.com/linux/fedora/gpg`. Any future
upstream change requires a deliberate edit of the vendored file in a PR.

**Why it matters**: supply-chain auditability. Reviewer of a future PR
can see exactly what the trust anchor for Docker installs is, without
diffing against external state.

## 3. `swtpm` always installed

**Upstream**: bazzite-dx uses `dnf5 --setopt=install_weak_deps=False
install` for the virt block. This skips `swtpm` because it's only
recommended (not required) by libvirt.

**Us**: explicit `swtpm swtpm-tools` in `build_files/dx/20-virtualization.sh`
(commit `906abd7`).

**Why it matters**: Windows 11 VMs require a TPM 2.0 to install. Without
swtpm on the host, `virt-manager` cannot create a working Windows 11 VM —
the user gets a confusing "this PC doesn't meet the requirements" wall.
Anyone testing Windows compat in a libvirt VM (i.e., most DX users) needs
swtpm. Bazzite-DX users currently have to layer it post-install.

## 4. VSCode `gpgcheck=1`

**Upstream**: bazzite-dx's install pattern sets `gpgcheck=0` on the vscode
repo with a `FIXME: gpgcheck broken on newer rpm policies` comment.

**Us**: `system_files/etc/yum.repos.d/vscode.repo` ships `gpgcheck=1`.
Verified empirically on Bazzite 44.20260501 / dnf5 5.x that the Microsoft
.asc key (0xBE1229CF, fingerprint
BC528686B50D79E339D3721CEB3E94ADBE1229CF) imports cleanly during the
first transaction touching the repo (commit `5e88c35`).

**Why it matters**: actual signature verification of the `code` package
on every install. The bazzite-dx FIXME comment was true for an earlier
dnf/rpm version; it has aged out. We catch the fix.

## 5. Single-flavour MX architecture

**Upstream**: bazzite-dx is a separate "DX-tier" image alongside
`bazzite-base`. Users have to choose which package to track and switching
requires `bootc switch`.

**Us**: bazzite-mx is the **only** flavour. The original plan had an
`IMAGE_TIER=base|dx` axis; collapsed early in the session (commit
`98dcba3`). Three GHCR images differ only in `BASE_IMAGE` (`bazzite`,
`bazzite-nvidia`, `bazzite-nvidia-open`) — picked by hardware, not by
"do I want DX features".

**Why it matters**: simpler mental model, simpler build matrix (3 jobs ×
2 streams instead of 6 × 2), no cognitive overhead of "am I on the right
flavour?". Trade-off: image size larger, ~15 GB. Acceptable for a personal
build.

## 6. `bazzite-mx-groups.service` for first-boot UX

**Upstream**: bazzite-dx-groups exists, but Bazzite base does not have
the equivalent — and bazzite-dx bundles its groups setup with several
other concerns. We split it cleanly.

**Us**: `system_files/usr/lib/systemd/system/bazzite-mx-groups.service`
+ `/usr/libexec/bazzite-mx-groups`. Oneshot at first boot adds wheel
users to `docker` and `libvirt` groups. Versioned via
`/etc/bazzite-mx/groups-version` so a script update re-runs (commit
`906abd7`, hardened in `3200764`).

**Why it matters**: without this, Phase 2's `docker.socket` is enabled
but the user can't `docker ps` without `sudo`. Phase 3's libvirt is
similarly inaccessible. UX regression that bazzite-dx upstream has
fixed but Bazzite base does not.

## 7. Phase 4 split: editor vs Git GUI

**Upstream**: bazzite-dx and Aurora-DX both bundle vscode + a few git
helpers (and gitkraken nowhere) under one big install script.

**Us**: `30-ide.sh` is editor-only (vscode); `35-git-tools.sh` is
GitKraken + `git-credential-libsecret`. Semantically separate
domains in separate scripts (commit `5a0dd78`). And we add
`git-credential-libsecret` (Aurora base only, missing from Bazzite
base AND bazzite-dx) for keyring-backed git auth.

**Why it matters**: clearer file-to-domain mapping; easier to add a
future "Git tools" item (e.g., `lazygit`) without bloating the IDE
script. `git-credential-libsecret` upgrades the day-1 git auth UX
on Bazzite for free.

## 8. VSCode `update.mode=none` atomic-correct default

**Upstream**: bazzite-dx ships the same setting plus opinionated font
(Cascadia Code) + theme defaults. AmyOS goes further with formatOnSave +
Hack Nerd Font + zsh terminal default + many style choices.

**Us**: `system_files/etc/skel/.config/Code/User/settings.json` is just
`{ "update.mode": "none" }`. The atomic-correctness fix only — no font,
no theme, no formatter opinion (commit `5a0dd78`).

**Why it matters**: distros should not impose stylistic preferences. The
fix is mandatory (VSCode's self-updater fights a read-only /usr); the
rest is the user's choice. Minimalism is a feature.

## 9. `bcc-tools` shipped alongside `bcc`

**Upstream**: both Aurora-DX (`build_files/dx/00-dx.sh:20`) and
bazzite-dx (`build_files/20-install-apps.sh:6`) install only `bcc`,
which is the BPF Compiler Collection **library** + Python bindings.
The actual command-line tracing utilities (`execsnoop`, `opensnoop`,
`tcpconnect`, `biotop`, `runqlat`, etc.) live in `bcc-tools`, a
separate ~2 MiB package that neither distro installs.

**Us**: `build_files/dx/40-dev-cli.sh` installs both `bcc` and
`bcc-tools` (commit `d7dc9c2`). The tools land under
`/usr/share/bcc/tools/<name>`.

**Why it matters**: a user typing `dnf install bcc` and then asking
"where's `execsnoop`?" gets answered out of the box on bazzite-mx.
On Aurora-DX or bazzite-dx, they have to layer `bcc-tools`
post-install. The 2 MiB cost is negligible for the UX gain.

## 10. `gh` from upstream vendored repo

**Upstream**: bazzite-dx does not install gh at all. Aurora's CLI list
(if it includes gh, which it doesn't appear to) would use Fedora's
package, currently at `gh-2.87.3-1.fc44`.

**Us**: vendored `system_files/etc/yum.repos.d/gh-cli.repo` pointing
at GitHub's official `https://cli.github.com/packages/rpm` with
`enabled=0`, `gpgcheck=1` against the upstream
`githubcli-archive-keyring.asc` (commit `d7dc9c2`). At install time
we use `dnf5 -y --enablerepo=gh-cli install gh`. The repo gives us
`gh-2.92.0` (released 2026-04-28) — multiple minor versions ahead
of the Fedora repo.

**Why it matters**: `gh` evolves quickly (new commands, GitHub API
features). Lagging by 5+ versions on a "DX" distro is a poor signal.
The vendoring pattern matches what we did for docker-ce.

## How to extend this list

When adding a new Phase, deliberately ask: **does this give us an edge
over upstream `bazzite-dx`?** If yes, document it here with:
- Commit hash that introduces it.
- What upstream does (or doesn't do).
- What we do.
- Why it matters in practice (concrete user-visible benefit).

If no, it's still a fine Phase, but the win-list isn't the place for it.
