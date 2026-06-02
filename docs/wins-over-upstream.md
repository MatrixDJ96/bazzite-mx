# Wins over `bazzite-dx` upstream

bazzite-mx is a personal fork that aims to be **strictly better** than
`ublue-os/bazzite-dx` upstream by adopting Aurora-DX's build patterns and
fixing concrete issues. **18 wins** are documented below; they
accumulate as each domain commit lands.

## Design philosophy

The product values that drive every win below:

- **Beat upstream, don't just track it.** Each domain aims to be strictly
  better than `bazzite-dx`; the aspiration is ≥1 real advantage per phase.
- **No opinionated defaults.** Stylistic choices (font, theme, formatter)
  are left to the user. AmyOS imposes choices — not our model; Bazzite-DX
  strips opinions — that *is* our model.
- **Skip when upstream does it better.** If Bazzite / Aurora-DX / AmyOS
  handle a domain better than we could, skipping is a win, not a forfeit
  (Phase 5 Cockpit is the canonical example — see [`workflow.md`](workflow.md)).

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



## 8. `bcc-tools` shipped alongside `bcc`

**Upstream**: both Aurora-DX (`build_files/dx/00-dx.sh:20`) and
bazzite-dx (`build_files/20-install-apps.sh:6`) install only `bcc`,
which is the BPF Compiler Collection **library** + Python bindings.
The actual command-line tracing utilities (`execsnoop`, `opensnoop`,
`tcpconnect`, `biotop`, `runqlat`, etc.) live in `bcc-tools`, a
separate ~2 MiB package that neither distro installs.

**Us**: `build_files/mx/40-dev-cli.sh` installs both `bcc` and
`bcc-tools`. The tools land under `/usr/share/bcc/tools/<name>`.

**Why it matters**: a user typing `dnf install bcc` and then asking
"where's `execsnoop`?" gets answered out of the box on bazzite-mx.
On Aurora-DX or bazzite-dx, they have to layer `bcc-tools`
post-install. The 2 MiB cost is negligible for the UX gain.

## 9. `gh` from upstream vendored repo

**Upstream**: bazzite-dx does not install gh at all. Aurora's CLI
list (if it includes gh, which it doesn't appear to) would use
Fedora's package, currently at `gh-2.87.3-1.fc44`.

**Us**: vendored `system_files/etc/yum.repos.d/gh-cli.repo` pointing
at GitHub's official `https://cli.github.com/packages/rpm` with
`enabled=0`, `gpgcheck=1` against the upstream
`githubcli-archive-keyring.asc`. At install time we use
`dnf5 -y --enablerepo=gh-cli install gh`. The repo gives us a `gh`
multiple minor versions ahead of the Fedora repo.

**Why it matters**: `gh` evolves quickly (new commands, GitHub API
features). Lagging by 5+ versions on a "DX" distro is a poor signal.
The vendoring pattern matches what we did for docker-ce.



## 10. Firefox from Mozilla's official RPM (vs. Flatpak)

**Upstream**: Bazzite installs Firefox as a Flathub flatpak
(`org.mozilla.firefox`) via its default-install list.

**Us**: Firefox via Mozilla's RPM repo, plus flatpak excluded from
default install + blocklisted from Discover/Bazaar + cleanup hooks
that uninstall any pre-existing per-user/per-system flatpak Firefox
on next boot/login.

**Why it matters**:
- Native messaging, system fonts, system policies, system keyring
  integration all work out-of-the-box — flatpak Firefox requires
  socket workarounds (xdg-desktop-portal-gtk, file-system access
  permissions, etc.) for several of these.
- One source of truth for security updates (Mozilla's release
  cycle, no flatpak runtime drifting from the base image).
- No accidental "two Firefoxes installed" surprise from a user
  clicking Discover's "Install Firefox" button.



## 11. Zero-maintenance third-party GPG keys

**Upstream**: bazzite-dx and Aurora-DX historically vendor GPG keys
statically under `system_files/etc/pki/rpm-gpg/`. When upstream
rotates a key, the vendored copy goes stale and the install starts
warning (or failing in strict mode).

**Us**:
- **RPM Fusion non-free**: install `rpmfusion-nonfree-release` (the
  release-info package). It ships keys for F44 / F45 / F46 / rawhide
  in a single rpm. Future Bazzite rebases against newer Fedora pull
  the corresponding key for free. The `.repo` files come with the
  same package (we sed `enabled=0` after install for isolation).
- **1Password**: `curl -fsSL https://downloads.1password.com/linux/
  keys/1password.asc` at build time. Every CI build re-fetches the
  current key. If 1Password rotates it, we get the new key on the
  next build (~1h via the upstream watcher).

**Why it matters**: zero maintenance debt for key rotation. A key
that goes stale on a vendored static copy is a slow ticking bomb;
we trade it for a per-build network call to the trust anchor
(documented as part of the "third-party `.repo` is `enabled=0`"
isolation invariant).



## 12. Docker group + libvirt group via system-setup hook (with sysusers.d for docker)

**Upstream**: bazzite-dx-groups exists but bundles its setup with
several other concerns. Bazzite base does not have an equivalent.
More critically, both Aurora-DX and Bazzite-DX inherit the
`docker-ce` postinstall-scriptlet gap: `groupadd --system docker`
in the rpm scriptlet is SUPPRESSED on rpm-ostree atomic systems
(rpm-ostree skips package scriptlets to keep the OCI layer
reproducible) — so the `docker` group never exists at runtime,
the user is never added to it, and every `docker run` requires
sudo. Verified: neither Aurora-DX nor Bazzite-DX ships a
sysusers.d for docker.

**Us**: two-piece fix:
- `system_files/usr/share/ublue-os/system-setup.hooks.d/
  10-bazzite-mx-groups.sh` runs at first boot via the
  `ublue-system-setup.service` framework (with `libsetup.sh
  version-script` for idempotency). Appends `docker` + `libvirt`
  groups to `/etc/group` from `/usr/lib/group`, then `usermod
  -aG` for every wheel user.
- `system_files/usr/lib/sysusers.d/bazzite-mx-docker.conf`: a
  single `g docker -` line that systemd-sysusers reads at
  sysinit.target (early in the boot sequence, before our
  group-adding hook). This creates the docker system group on
  every boot, exactly compensating the suppressed rpm scriptlet.

**Why it matters**: without this, Phase 3's `docker.socket` is
enabled but the user can't `docker ps` without `sudo`. Phase 4's
libvirt is similarly inaccessible. UX regression that bazzite-dx
upstream has fixed only partially.



## 13. Idempotent justfile import + `_pkg_layered` reusable helper

**Upstream**: Bazzite-DX (`60-clean-base.sh:5`) and AmyOS
(`install-apps.sh:107`) append their `import` directive to Bazzite's
master justfile **without** an idempotency check — the line is
appended on every build, accumulating duplicates if the same script
runs twice (e.g., during local pre-flights).

**Us**: `55-justfile-import.sh` uses `grep -qxF "$IMPORT_LINE"
"$MASTER" || echo "$IMPORT_LINE" >> "$MASTER"` — the line is
appended only if not already present. Side-effect-free re-runs.

`95-bazzite-mx.just` ships a `_pkg_layered` helper recipe that
checks rpm-ostree overlay layer membership (not `rpm -q`, which
sees base-image packages too) and returns `yes`/`no` on stdout
rather than via exit code. Reason: `just` always emits
`error: Recipe X failed on line N with exit code 1` when a
sub-recipe exits non-zero, even when wrapped in the caller's `if`.
The stdout-as-boolean pattern keeps install-* output clean.

**Why it matters**: clean recipe UX, no spurious "error" lines on
re-run, and a reusable layering-check helper for any future
`install-*` recipe.



## 14. VSCode extensions hardened against libsetup.sh state-before-body race

**Upstream**: Bazzite-DX has the same race in their vscode-extensions
hook but never noticed because their hook has no failure modes more
sensitive than ours. Aurora-DX dodges the race by writing state at
the END of their custom libexec (no libsetup.sh).

**Race**: `libsetup.sh::version-script` writes the versioned state
file BEFORE the hook body runs. Under `set -euo pipefail`, a single
failed command (transient marketplace timeout, missing skel file,
…) aborts the hook AFTER the state has been committed → next login
skips the hook → silent permanent disable.

**Us**: every `code --install-extension X` has `|| true` so failure
becomes benign and the hook completes (state correctly reflects "I
tried"). Source paths in the hook (`/etc/skel/.config/Code/User/
settings.json`) are guarded with `[ -e ... ]` so a future skel
removal doesn't trigger the trap.

**Why it matters**: a one-time login glitch (network blip when
fetching from the marketplace) on the original would silently
disable the hook forever — the user's `code` would never get the
3 expected extensions auto-installed, and they'd never know why.

## 15. `gparted` ships to fill the gap Bazzite leaves

**Upstream**: Bazzite **removes** `kde-partitionmanager` from their
KDE base (commit `378e524a`, Plasma 6.4 cleanup) and does NOT
replace it with anything else. The bootc deployment image therefore
ships **with no GUI partition tool** — only CLI `parted` / `fdisk`
survive. Bazzite's own ISO installer hook installs gparted but
only into the live ISO environment, not into the deployed system.

**Us**: `build_files/mx/60-desktop-apps.sh` ships `gparted` (~9
MiB) as a universal partition manager. Provenance also reinforced
by AmyOS, which ships gparted in their DX-style list.

**Why it matters**: a daily-driver workstation needs a GUI
partition tool. Discovering only at the moment of need that
`kde-partitionmanager` is gone (and the live-ISO gparted is not
on the deployed system) would mean dropping to terminal `parted`
or rebooting from USB.



## 16. Sunshine reintegrated as system RPM (vs. Bazzite's brew migration)

**Upstream**: Bazzite shipped Sunshine as a system RPM from the
`lizardbyte/beta` COPR until commit `079fa8ad` (2026-03-26), then
removed it citing "numerous ignored issues about their stable repo
not supporting Fedora 43 these last 6 months." Their replacement
is a Homebrew-based `setup-sunshine` recipe (commit `aa6ec9da`)
that requires the user to install Homebrew first, then `brew
install sunshine` — which downloads and *compiles* a 30+ MiB
binary on every machine.

**Us**: `build_files/mx/65-sunshine.sh` installs Sunshine
as a system RPM via `lizardbyte/stable` — the same COPR Aurora
uses, carrying current Fedora 44 builds. Three pieces:
1. `copr_install_isolated "lizardbyte/stable" "sunshine"`: same
   isolated-COPR pattern we use for `ublue-os-libvirt-workarounds`.
2. `setcap cap_sys_admin+p` on `/usr/bin/sunshine` for KMS-based
   capture. The COPR package does NOT ship the cap; without it
   Sunshine falls back to a slower PipeWire portal path.
3. `systemctl --global disable app-dev.lizardbyte.app.Sunshine
   .service`: defense-in-depth (Aurora pattern). The user-service
   is `disabled` by default (no preset ships); user opts in via
   `ujust setup-sunshine enable`.

Recipe override (`system_files/usr/share/ublue-os/just/82-bazzite-
sunshine.just`): replaces Bazzite's brew-flavored recipe with our
RPM-flavored version. Manages `app-dev.lizardbyte.app.Sunshine
.service` (the COPR-shipped user unit) via `systemctl --user
enable --now`.

Nag suppression: `/usr/share/ublue-os/announcements/sunshine-
brew.msg.json` shows users a "Sunshine will soon be removed" nag
whenever they have a Sunshine config. With our RPM integration
the nag is permanently misleading; we `rm` it at build time.

**Why it matters**: brew-on-ostree adds ~30 minutes of first-run
install time (compile from source on a mid-tier laptop), an
unsupported package manager dependency, and a slower update path
(`brew upgrade` is per-user, manual). RPM integration brings
Sunshine back to first-class status: same speed of install (zero
— already there), `bootc upgrade` updates, no brew prerequisite,
and works on a fresh deployment without any user setup.

## 17. Rechunker enabled by default (vs. Bazzite-DX/AmyOS template-commented-out)

**Upstream**: Bazzite-DX (`build.yml:155-181`) and AmyOS
(`build.yml`, similar) both ship the rechunker step **commented
out** in their template, with a comment block telling the user to
"uncomment if you want it". Default behavior on a fresh fork:
no rechunking, the published image is one giant overlay layer per
build. Aurora-DX takes a different path: a custom `just rechunk`
recipe wrapping the `hhd-dev/rechunk` action; activated by default.

**Us**: rechunker enabled by default in
`.github/workflows/reusable-build.yml` using bootc's native
`rpm-ostree compose build-chunked-oci`. Choice over `hhd-dev/
rechunk`:
- No external action version pin to maintain — runs in-image, the
  version shipped is exactly what bazzite ships.
- Integrates cleanly with our cosign-by-digest signing (no
  re-tagging dance).
- `--bootc --max-layers 127 --format-version 2` matches Bazzite's
  internal pattern, maximising cross-image dedup with the base.

**Cost**: ~+15 min wall-clock on the 6-job matrix (~13-15 min per
job, parallel).

**Why it matters**: a fresh-fork user who copy-pastes the
Bazzite-DX template gets a rechunkless image silently, then has
to discover the gap (typically when their users hit slow /
non-resumable downloads or when they run out of GHCR storage
quota faster than expected). We surface the choice explicitly,
default it to "on", and document the trade-off here so the cost
is visible.

## 18. Full MSI laptop EC control — working module + GUI (vs. obsolete in-tree)

**Upstream**: the Bazzite `-ogc` kernel ships an **in-tree `msi-ec.ko`**
that is a stale mainline snapshot. On recent MSI hardware it rejects the
machine's EC firmware outright — e.g. on a Katana 17 (`17L5EMS1.115`),
`modprobe msi-ec` fails with *"Firmware version is not supported"*. The
kernel is also built with `CONFIG_ACPI_EC_DEBUGFS` off, so `ec_sys`
cannot load and `/sys/kernel/debug/ec/` never appears — leaving any fan
GUI without a backend. No control application is shipped. Net result on
Bazzite: fan modes, shift modes, cooler-boost, and fan curves are
**unavailable** on otherwise-supported MSI laptops.

**Us**: two out-of-tree modules built at image-build time by a generic
kmod builder (`build_files/kmods/build-kmods.sh`) and installed into
`updates/` (highest depmod priority, so they override the obsolete
in-tree copy with no override file):
- **`msi-ec`** from BeardOverflow upstream, pinned commit `e538f85`
  (`build_files/kmods/msi-ec/source.env`, `build_files/mx/70-msi-ec.sh`)
  — the current driver that *does* whitelist recent firmware.
- **`acpi_ec`** from `saidsay-so/acpi_ec`, pinned tag `v1.0.4` /
  `75102ce` (`build_files/kmods/acpi_ec/source.env`,
  `build_files/mx/71-acpi-ec.sh`) — creates the root-only `/dev/ec`
  char device, the fallback backend MControlCenter uses when the
  `ec_sys` debugfs node is absent, carrying both fan-RPM reads and
  fan-curve writes.

The control GUI — **MControlCenter**, the app cited by msi-ec's own
README — ships from the `teackot/msi` COPR (`teackot-msi.repo`
vendored `enabled=0`). Everything is wired into a single opt-in recipe
`ujust setup-msi enable|disable` (`95-bazzite-mx.just`): `enable` loads
both modules, persists autoload, and layers the GUI; `disable` reverses
all three. No autoload is shipped in the image.

**Why it matters**: out of the box on Bazzite, an MSI-laptop owner gets
a fan controller that silently won't load and no app to drive it.
Bazzite MX makes fan modes, shift modes, cooler-boost, the
battery-charge threshold, and fan curves actually work, with a GUI —
verified on the maintainer's Katana 17. It stays **opt-in** (no autoload,
no GUI layered by default) so users on non-MSI hardware pay nothing,
honouring the "no opinionated defaults" principle. Commits: `5345456`
(acpi_ec), `4b7f9da` (GUI), `5987e62` (unified recipe).

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
