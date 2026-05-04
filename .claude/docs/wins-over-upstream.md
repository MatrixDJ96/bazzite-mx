# Wins over `bazzite-dx` upstream

bazzite-mx is a personal fork that aims to be **strictly better** than
`ublue-os/bazzite-dx` upstream by adopting Aurora-DX's build patterns and
fixing concrete issues. **7 wins** as of the IDE commit;
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



## 3. `swtpm` always installed

**Upstream**: bazzite-dx uses `dnf5 --setopt=install_weak_deps=False`
for the virt block. This skips `swtpm` because it's only recommended
(not required) by libvirt.

**Us**: explicit `swtpm swtpm-tools` in
`build_files/mx/20-virtualization.sh`.

**Why it matters**: Windows 11 VMs require a TPM 2.0 to install.
Without swtpm on the host, virt-manager cannot create a working
Windows 11 VM — the user gets a confusing "this PC doesn't meet the
requirements" wall. Anyone testing Windows compat in a libvirt VM
(i.e., most DX users) needs swtpm. Bazzite-DX users currently have
to layer it post-install.

## 4. Working virt stack out-of-the-box (vs. silently broken upstream recipe)

**Upstream**: Bazzite (and Bazzite-DX) ship `setup-virtualization`
as a ujust recipe gated on `if ! rpm -q virt-manager | grep -P
"^virt-manager-"`. On a stock Bazzite image where virt-manager is
NOT pre-installed the recipe runs the full `flatpak install
…virt-manager` + `rpm-ostree kargs` + swtpm dir + libvirtd-enable
path. But on Bazzite-DX, where the user is expected to layer
virt-manager themselves, the gate is also FALSE (no RPM), so the
flatpak path runs — duplicating the eventual RPM install if the
user later layers it. Neither upstream image enables
`libvirtd.service` at build, so a fresh boot has the full virt
stack but disabled — clicking virt-manager fails until the user
runs the recipe.

**Us**: Three-layer fix delivered together:
1. **Build-time enable** (`build_files/mx/20-virtualization.sh`):
   `systemctl enable libvirtd.service` runs at image build, so the
   service is `enabled` on first boot. Pattern lifted from AmyOS,
   the only one of the three reference distros that gets this right
   out-of-the-box.
2. **Build-time kargs** (`system_files/usr/lib/bootc/kargs.d/
   01-bazzite-mx-virt.toml`): ships `kvm.ignore_msrs=1` +
   `kvm.report_ignored_msrs=0` so Windows 11 guests don't panic on
   unimplemented-MSR reads. Bootc applies these at deploy time.
3. **Recipe override** (`system_files/usr/share/ublue-os/just/
   84-bazzite-virt.just`): replaces Bazzite's `setup-virtualization`
   with our own version. We drop the `! rpm -q virt-manager` gate
   (always-broken on bazzite-mx since we ship the RPM), drop the
   `flatpak install …virt-manager` line (would duplicate the RPM),
   drop the redundant kargs/libvirtd bits (already done at build
   time). Kept verbatim: VFIO / kvmfr / USB-hot-plug / libvirt-group
   blocks, which handle hardware-passthrough scenarios orthogonal
   to the basic stack.

Defense-in-depth: `build_files/mx/21-virt-manager-flatpak-exclude.sh`
adds `deny org.virt_manager.virt-manager/*` to `/usr/share/ublue-os/
flatpak-blocklist` so Discover/Bazaar hide the flatpak from search
results. Two cleanup hooks (`system-setup.hooks.d/16-cleanup-virt-
manager-flatpak.sh` + same under `user-setup.hooks.d/`) `flatpak
uninstall` any pre-existing namespace via `libsetup.sh
version-script`.

**Why it matters**: a virt stack that's installed but disabled is a
surprise-failure on first VM creation. The 3 reference distros each
get part of this right — AmyOS enables libvirtd; Aurora-DX adds the
flatpak; Bazzite has the most complete recipe; **none** ship a
working-on-first-boot stack while also providing a working recipe
for VFIO advanced users. Our single image gives both. Net effect:
opening virt-manager.app from the launcher post-install just works.



## 5. VSCode `gpgcheck=1`

**Upstream**: bazzite-dx's install pattern sets `gpgcheck=0` on the
vscode repo with a `FIXME: gpgcheck broken on newer rpm policies`
comment.

**Us**: `system_files/etc/yum.repos.d/vscode.repo` ships `gpgcheck=1`.
Verified empirically on Bazzite 44 / dnf5 5.x that the Microsoft .asc
key (0xBE1229CF, fingerprint
BC528686B50D79E339D3721CEB3E94ADBE1229CF) imports cleanly during the
first transaction touching the repo.

**Why it matters**: actual signature verification of the `code`
package on every install. The bazzite-dx FIXME comment was true for
an earlier dnf/rpm version; it has aged out. We catch the fix.

## 6. `git-credential-libsecret` shipped (Aurora-only otherwise)

**Upstream**: Aurora base ships `git-credential-libsecret`. Bazzite
base does NOT, and Bazzite-DX inherits the gap.

**Us**: `35-git-tools.sh` installs `git-credential-libsecret` so
git authentication via system keyring works out-of-the-box. Day-1
git auth UX upgrade for free.

**Why it matters**: GUI password prompts via the keyring vs. typing
HTTPS tokens / pasting them into terminal each push. Standard
modern git auth on Linux desktops.

## 7. VSCode `update.mode=none` atomic-correct default

**Upstream**: bazzite-dx ships the same setting plus opinionated
font (Cascadia Code) + theme defaults. AmyOS goes further with
formatOnSave + Hack Nerd Font + zsh terminal default + many style
choices.

**Us**: `system_files/etc/skel/.config/Code/User/settings.json` is
just `{ "update.mode": "none" }`. The atomic-correctness fix only
— no font, no theme, no formatter opinion.

**Why it matters**: distros should not impose stylistic preferences.
The fix is mandatory (VSCode's self-updater fights a read-only
`/usr`); the rest is the user's choice. Minimalism is a feature.

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
