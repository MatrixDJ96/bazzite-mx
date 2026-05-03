# Wins over `bazzite-dx` upstream

bazzite-mx is a personal fork that aims to be **strictly better** than
`ublue-os/bazzite-dx` upstream by adopting Aurora-DX's build patterns and
fixing concrete issues. Cumulative wins as of 2026-05-03: **17 wins**.

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

**Us**: explicit `swtpm swtpm-tools` in `build_files/mx/20-virtualization.sh`
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

**Us**: `build_files/mx/40-dev-cli.sh` installs both `bcc` and
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

## 11. More complete `ublue-setup-services` adoption

**Upstream**: bazzite-dx is the only adopter of `ublue-setup-services`
across the wider ublue ecosystem (Aurora, Aurora-DX, AmyOS, Bazzite
base do not use it as of 2026-05-02). And even bazzite-dx uses the
framework only partially:
- VSCode extensions hook (`/usr/share/ublue-os/user-setup.hooks.d/11-vscode-extensions.sh`) — uses `libsetup.sh` ✓
- Privileged-setup hook (`/usr/share/ublue-os/privileged-setup.hooks.d/20-dx.sh`) — uses `libsetup.sh` ✓
- `bazzite-dx-groups` — **does NOT use libsetup.sh**, keeps a custom
  versioning file at `/etc/ublue/dx-groups`.

**Us**: every setup-time script in bazzite-mx uses the framework
(commit `40611b1`). `bazzite-mx-groups` was migrated from a
custom systemd service + custom version file to a system-setup hook
at `/usr/share/ublue-os/system-setup.hooks.d/10-bazzite-mx-groups.sh`,
sourcing `libsetup.sh` and calling `version-script bazzite-mx-groups
system 1`. All versioning state is now centralized in one JSON file
(`/var/roothome/.local/share/ublue/setup_versioning.json`).

**Why it matters**: Phase 8 will add more setup hooks (vscode
extensions, tailscale init, etc.). Mixing two versioning patterns
(custom file + JSON) would be confusing and harder to debug. Going
all-in on the framework now means every future hook follows the same
pattern.

## 12. Firefox from Mozilla's official RPM repo

**Upstream**: bazzite-dx, Bazzite base, and the entire ublue ecosystem
(Aurora, Aurora-DX, AmyOS) ship Firefox only as a Flathub flatpak
(`org.mozilla.firefox`, in Bazzite's default-install list).

**Us**: `system_files/etc/yum.repos.d/mozilla.repo` is vendored
(`enabled=0`, `priority=10`, `gpgcheck=1`, `repo_gpgcheck=0` per
Mozilla docs). `build_files/mx/45-firefox-rpm.sh` removes any pre-
existing `firefox` from the Fedora repo (gated by `rpm -q`) and
installs `firefox` + `firefox-l10n-it` from the Mozilla repo
(commit `5d17d01`, fix-forward review in `b71b0e1`). The smoke test
asserts `VENDOR=Mozilla` as a guard against regression to the
Fedora package.

**Why it matters**: 1Password's native-messaging socket (browser
autofill) is blocked by the flatpak sandbox. The Mozilla RPM solves
that out-of-the-box. Bonus: no flatpak-runtime drift from system
libraries (glibc/mesa/...).

## 13. Migration cleanup hooks for pre-existing flatpaks

**Upstream**: no ublue distro handles user flatpak state migration
when the distro switches provider for an app (e.g. from flatpak
to rpm).

**Us**: two complementary hooks (commit `550c4f1`):
- `system-setup.hooks.d/15-cleanup-firefox-flatpak.sh` (root, oneshot
  via `ublue-system-setup.service`) — `flatpak uninstall --system
  org.mozilla.firefox`.
- `user-setup.hooks.d/15-cleanup-firefox-flatpak.sh` (per-user, via
  `ublue-user-setup.service --user`) — `flatpak uninstall --user
  org.mozilla.firefox`.

Both versioned via `version-script cleanup-firefox-flatpak
{system,user} 1` from `libsetup.sh`. Bumping the version number →
the hook re-runs automatically on next boot/login, with no user
intervention.

**Why it matters**: anyone upgrading from a pre-Phase-8 bazzite-mx
still has the Firefox flatpak installed locally. Without the cleanup
hooks they would end up with TWO Firefox installs (rpm + flatpak),
and the KDE icon launcher might point to the stale flatpak. The
pattern is generic: any future "flatpak → rpm" migration can reuse
the same layout.

## 14. RPM Fusion + 1Password integrated with zero maintenance debt

**Upstream**:
- Bazzite and Bazzite-DX **do not integrate** RPM Fusion at all.
- Aurora has only a *defensive* loop (`build_files/dx/00-dx.sh:139`,
  `build_files/base/17-cleanup.sh:79`) that disables rpmfusion-* if
  they happen to be enabled, but neither vendors the `.repo` files
  nor installs packages from Fusion.
- AmyOS is the only ublue distro that integrates RPM Fusion
  actively, but the way it acquires the `.repo` files isn't explicit
  in `install-apps.sh` (probably inherited from the base image), and
  it's only used to install `audacious` + `audacity-freeworld`.
- For 1Password, no ublue distro has integration (the official
  1Password docs always require `rpm --import URL` + manual `.repo`
  creation).

**Us** (initial commit `12709cf`, refactor `8d9152f`): zero-debt
maintenance approach for both repos:
- `build_files/mx/47-rpmfusion-release.sh`: install
  `rpmfusion-nonfree-release-$(rpm -E %fedora)` as an rpm package
  (5.9 KB). The package ships GPG keys for Fedora 2020/44/45/46/
  latest/rawhide and the 3 `.repo` files (release/updates/updates-
  testing). A sed disables every section to a baseline `enabled=0`.
- `build_files/mx/48-1password-key.sh`: `curl -fsSL` of the official
  key from `https://downloads.1password.com/linux/keys/1password.asc`
  on every build. A PGP-block sanity check fails the build if
  1Password returns garbage.
- `system_files/etc/yum.repos.d/1password.repo` stays vendored (our
  policy: `enabled=0`, `repo_gpgcheck=1`).

**Why it matters**: zero responsibility for key rotation on our side.
When RPM Fusion rotates its key (rare, but happens at major Fedora
releases), the upstream release package picks it up automatically —
`bootc upgrade` ships it. When 1Password rotates its key, the next
hourly rebuild via watch-upstream re-fetches it fresh. **Bazzite-DX
and AmyOS have the same option available and choose to vendor
instead** — meaning their debt is latent, ours is structurally zero.
Future-proof for Fedora 45/46 with no manual intervention.

## 15. `ujust install-{discord,1password}` opt-in pattern + reusable `_pkg_layered` helper

**Upstream**: Bazzite's `82-bazzite-apps.just` has recipes like
`install-coolercontrol`, `install-displaylink`,
`install-jetbrains-toolbox`, etc. — but **neither `install-discord`
nor `install-1password`**, and each recipe redefines its own bash
`layered()` function inline (duplication). bazzite-dx adds no
`install-*` recipes (their `95-bazzite-dx.just` only has
`dx-group`, `install-fonts`, `toggle-gamemode`). Aurora-DX and
AmyOS don't ship a custom justfile.

**Us**: the first MX justfile with two distinct opt-in recipes:
- `system_files/usr/share/ublue-os/just/95-bazzite-mx.just`
- `[private] _pkg_layered pkg` — a **reusable** helper using
  `rpm-ostree status --json | jq` to check the booted deployment.
  Hardened with `// []` fallback (safe when the deployment has zero
  layered packages or no booted deployment, e.g. in CI). Outputs
  `yes`/`no` on stdout (always exits 0) instead of using `jq -e`'s
  exit code as a boolean signal: `just` would otherwise spuriously
  log `error: Recipe '_pkg_layered' failed on line N with exit code
  1` for every sub-recipe that exits non-zero, even when wrapped in
  the caller's `if` — polluting every `install-*`'s output (commit
  `a1cbdab`). Unlike Bazzite's pattern (a `layered()` function
  redefined inline per recipe), ours is DRY: every new `install-*`
  recipe just does `if [ "$(just _pkg_layered <pkg>)" = "yes" ];
  then ...; fi`.
- `[group("apps")] install-discord` (commit `12709cf`) — RPM Fusion
  non-free, `sed '0,/^enabled=0/{...}'` (main section only, not
  debuginfo+source), explicit `sudo rpm-ostree install`.
- `[group("apps")] install-1password` (commit `ec1acf0`) — official
  1Password repo (`downloads.1password.com`), single-section file so
  a simple `sed 's/^enabled=0/enabled=1/'`. GPG key fetched at build
  time by `48-1password-key.sh` (refactor `8d9152f`) to support
  `repo_gpgcheck=1` without runtime `rpm --import`.

**Why it matters**: Discord has weekly updates and an intrusive
"Update Available" nag that on an atomic distro the user can't
dismiss via `dnf update`. 1Password's native-messaging integration
is blocked by the flatpak sandbox. The opt-in ujust pattern means
users who don't install the app never enable the repo → no extra
metadata fetched on `bootc upgrade`. Users who do install benefit
from automatic updates via `ujust update` without manual
intervention (the repo stays `enabled=1` post-install). We're the
first in the ublue ecosystem with these recipes **and** with a
reusable `_pkg_layered` helper (upstreams duplicate the logic).

## 16. VSCode extensions user-setup hook hardened against libsetup state-before-body race

**Upstream**: Bazzite-DX shipped (`11-vscode-extensions.sh`) and
Aurora-DX (`/usr/libexec/aurora-dx-user-vscode`) both pre-install the
same 3 Microsoft container/remote extensions at first user login.
Bazzite-DX uses `libsetup.sh::version-script` (state-first), Aurora-DX
uses a hand-rolled state file written at the END of the script.
**Bazzite-DX has a silent race**: `version-script` writes the state
file BEFORE the hook body runs. Under `set -e`, a single failed
`code --install-extension` (transient marketplace timeout) aborts the
hook AFTER state has been committed → next login skips → silent
permanent disable. Aurora-DX dodges the race by writing state at end.

**Us**: `system_files/usr/share/ublue-os/user-setup.hooks.d/11-vscode-extensions.sh`
adopts the Bazzite-DX libsetup.sh pattern (DRY, no custom state-file
plumbing) but **closes the race in 3 ways** identified by formal code
review (commit `46da707`):
1. `\|\| true` after each `code --install-extension` — marketplace-down
   is benign (no state corruption, no dependency failure); failed
   extensions just don't install, the next 2 still try, hook exits
   green and state is correctly "I tried." Documented exception to
   the conventions.md "no `\|\| true`" rule, justified inline.
2. Source-path guard on the `cp /etc/skel/.../settings.json` — a
   future skel-file removal would otherwise abort the hook before
   the install lines run, triggering the same trap.
3. Smoke test asserts the 3 extension IDs by ID alone (not the
   exact `code --install-extension X` syntax), so a future hook
   refactor doesn't break the test for the wrong reason.

**Why it matters**: a transient WiFi or Microsoft Marketplace outage
on a user's first login would otherwise silently disable the feature
forever. Strictly safer than Bazzite-DX. Provenance peer-reviewed
against Aurora-DX (which has the safer end-write pattern but not via
a shared `libsetup.sh` framework).

## 17. `gparted` ships to fill the gap Bazzite leaves

**Upstream**: Bazzite **removes** `kde-partitionmanager` from their
KDE base (commit `378e524a`, `Containerfile:421` of their repo) as
part of the Plasma 6.4 cleanup. They do NOT replace it with anything
else. The bootc deployment image therefore ships **with no GUI
partition tool** — `kde-partitionmanager` is gone, gparted is not
included, only CLI tools like `parted`, `fdisk` survive. Bazzite's
own ISO installer hook (`titanoboa_hook_postrootfs.sh:313`) installs
gparted but only into the live ISO environment, not into the
deployed system.

**Us**: `build_files/mx/60-desktop-apps.sh` ships `gparted` (~9 MiB)
as a universal partition manager for daily disk operations (USB
stick prep, dual-boot resizes, external-drive formatting). Provenance
also reinforced by AmyOS, which ships gparted in their DX-style
list (`install-apps.sh:22`).

**Why it matters**: a daily-driver workstation needs a GUI partition
tool. Discovering only at the moment of need that `kde-partitionmanager`
is gone (and the live-ISO gparted is not on the deployed system)
would mean dropping to terminal `parted` or rebooting from USB. We
restore the functionality Bazzite removed without justification. Pure
1-line build addition; zero maintenance.

## How to extend this list

When adding a new Phase, deliberately ask: **does this give us an edge
over upstream `bazzite-dx`?** If yes, document it here with:
- Commit hash that introduces it.
- What upstream does (or doesn't do).
- What we do.
- Why it matters in practice (concrete user-visible benefit).

If no, it's still a fine Phase, but the win-list isn't the place for it.
