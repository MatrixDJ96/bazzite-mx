# Intentional divergences from upstream

bazzite-mx layers on `ublue-os/bazzite` and borrows heavily from `bazzite-dx`, Aurora-DX, and
AmyOS — those projects do the heavy lifting, and most domains are adopted as-is. Where this
project's use case (a single-maintainer dev & sysadmin workstation) calls for a different
choice, the divergence is deliberate and recorded here with provenance and rationale, so future
sessions don't re-derive it; entries accumulate as each domain commit lands.

## Design philosophy

The product values that drive every divergence below:

- **Diverge deliberately, don't drift.** Each domain is compared against upstream and changed
  only where our use case differs; the aspiration is at least one substantive, documented
  divergence per phase.
- **No opinionated defaults.** Stylistic choices (font, theme, formatter) are left to the user.
  AmyOS bakes in its maintainer's preferences — a sound choice for a personal OS, but not our
  model; Bazzite-DX keeps defaults unopinionated, and that *is* our model.
- **Adopt upstream when it fits.** If Bazzite / Aurora-DX / AmyOS already handle a domain the
  way this project needs, adopting it as-is is a deliberate outcome, not a forfeit (Phase 5
  Cockpit is the canonical example — see [`workflow.md`](workflow.md)).

## 1. Strict repo isolation via `validate-repos.sh`

**Upstream**: no equivalent — bazzite-dx trusts that the install order leaves no third-party
repo enabled.

**Us**: `build_files/shared/validate-repos.sh` runs at the end of every build and hard-fails if
any file listed in `build_files/shared/third-party-repos.list` (or any `_copr:*` / `_copr_*` /
`rpmfusion-*`) has `^enabled=1`, plus an informational catch-all sweep listing every other
`.repo` file so an unregistered third-party repo is visible in PR review. The list is a file
rather than Aurora's inline array so the post-rechunk `check-image-integrity.sh` enforces the
same entries on the cold bytes without a second copy that could drift.

**Why it matters**: a deployed `bootc upgrade` re-reads `/etc/yum.repos.d/`; a leftover
`enabled=1` on `docker-ce.repo` would silently pull docker package updates from docker.com on
every upgrade, breaking the reproducibility we promise.

## 2. `docker-ce.repo` vendored in git

**Upstream**: `dnf5 config-manager addrepo --from-repofile=https://download.docker.com/...`
fetched at build time, every time — no auditable diff in git if Docker changes the .repo format
/ baseurl / gpgkey.

**Us**: `system_files/etc/yum.repos.d/docker-ce.repo` committed — single `[docker-ce]` section
with `enabled=0`, `gpgcheck=1`, `gpgkey=https://download.docker.com/linux/fedora/gpg`. Any
upstream change requires a deliberate edit of the vendored file in a PR.

**Why it matters**: supply-chain auditability — a PR reviewer sees the exact trust anchor for
Docker installs without diffing against external state.

## 3. `swtpm` always installed

**Upstream**: bazzite-dx installs the virt block with `dnf5 --setopt=install_weak_deps=False`,
which skips `swtpm` because it is only recommended (not required) by libvirt.

**Us**: explicit `swtpm swtpm-tools` in `build_files/mx/20-virtualization.sh`.

**Why it matters**: Windows 11 VMs require a TPM 2.0 to install; without swtpm the user hits a
confusing "this PC doesn't meet the requirements" wall in virt-manager. On Bazzite-DX the
package is layered post-install.

## 4. Working virt stack out-of-the-box

Troubleshooting entry: gotcha #5 in [`gotchas.md`](gotchas.md).

**Upstream**: Bazzite's `setup-virtualization` recipe is flatpak-only (commit `8f1c46b4`,
2026-05-05, "portal parity" — the rpm gate and the VFIO / kvmfr / usbhp / group branches are
gone): `virt-on` installs the org.virt_manager.virt-manager flatpak (+ QEMU extension) whenever
`flatpak info` misses it. On bazzite-mx that branch would always fire, duplicating the
build-time RPM and fighting the flatpak blocklist. The full recipe — gated on
`if ! rpm -q virt-manager | grep -P "^virt-manager-"`, plus the VFIO / kvmfr / usbhp / group
blocks — lives on in bazzite-dx's own `84-bazzite-virt.just` override (@ `de81a7c`), the real
source of our verbatim blocks; there the gate is permanently FALSE once the user layers the
RPM. Neither image enables `libvirtd.service` at build — a fresh boot has the full virt stack,
disabled.

**Us**: three-layer fix delivered together, because our use case ships virt-manager as an RPM
at build time and wants VMs working on first boot:

1. **Build-time enable** (`build_files/mx/20-virtualization.sh`):
   `systemctl enable libvirtd.service` at image build, so the service is `enabled` on first
   boot — our build-time enable; no reference distro ships it.
2. **Build-time KVM module options** (`system_files/usr/lib/modprobe.d/bazzite-mx-kvm.conf`):
   ships `kvm.ignore_msrs=1` + `kvm.report_ignored_msrs=0` so Windows 11 guests don't panic on
   unimplemented-MSR reads. kmod applies them at every `kvm.ko` load, on bootc- and
   rpm-ostree-managed deployments alike (a bootc kargs.d TOML reaches only bootc-managed ones —
   see gotcha 18).
3. **Recipe override** (`setup-virtualization` in
   `system_files/usr/share/ublue-os/just/96-bazzite-mx-overrides.just`, with the upstream copy
   surgically removed from `84-bazzite-virt.just` by
   `build_files/mx/55-justfile-reconcile.sh`): our recipe tracks bazzite-dx's full override.
   Relative to that recipe it drops the `! rpm -q virt-manager` gate (permanently FALSE on
   bazzite-mx since we ship the RPM), the `flatpak install …virt-manager` line (would duplicate
   the RPM), the redundant kargs/libvirtd bits (done at build time), and the
   `kvm.report_ignored_msrs` karg sentinel gating `vfio-on` (no such karg exists here). kvmfr /
   USB-hot-plug / libvirt-group blocks kept verbatim from bazzite-dx for hardware-passthrough
   scenarios orthogonal to the basic stack — including its
   `/usr/libexec/bazzite-dx-kvmfr-setup` helper, which bazzite-dx ships in its own image and we
   vendor byte-identical in `system_files/usr/libexec/` (mode 755) so the kvmfr branch works on
   a non-dx base image. The VFIO blocks carry five further deviations of their own, which
   divergence #22 owns.

Defense-in-depth: `build_files/mx/21-virt-manager-flatpak-exclude.sh` adds
`deny org.virt_manager.virt-manager/*` to `/usr/share/ublue-os/flatpak-blocklist` so
Discover/Bazaar hide the flatpak, and two cleanup hooks
(`16-bazzite-mx-virt-manager-flatpak-cleanup.sh` under both `system-setup.hooks.d/` and
`user-setup.hooks.d/`) `flatpak uninstall` any pre-existing namespace via
`libsetup.sh version-script`.

**Why it matters**: an installed-but-disabled virt stack is a surprise failure on first VM
creation. Each upstream covers a piece of the picture: Bazzite's recipe serves the flatpak use
case, bazzite-dx's override carries the full VFIO recipe. Our use case wants a
working-on-first-boot stack plus a working VFIO recipe in a single image, so we combine the
pieces: opening virt-manager from the launcher post-install just works.

## 5. VSCode `gpgcheck=1`

**Upstream**: bazzite-dx used to set `gpgcheck=0` on the vscode repo with a
`FIXME: gpgcheck broken on newer rpm policies` comment. Since `fd8ba65` it adds Microsoft's own
repofile instead
(`dnf5 config-manager addrepo --from-repofile=https://packages.microsoft.com/yumrepos/vscode/config.repo`,
repo id `vscode-yum`) — and that file ships `gpgcheck=0` **and** `repo_gpgcheck=0` of its own
(MEASURED 2026-09-01, fetched from the URL above). The FIXME is gone; the unverified install is
not, it just comes from the vendor now.

**Us**: `system_files/etc/yum.repos.d/vscode.repo` ships `gpgcheck=1` with
`gpgkey=https://packages.microsoft.com/keys/microsoft.asc` — verified empirically on Bazzite 44
/ dnf5 5.x that the Microsoft .asc key (0xBE1229CF, fingerprint
BC528686B50D79E339D3721CEB3E94ADBE1229CF) imports cleanly during the first transaction touching
the repo.

**Why it matters**: actual signature verification of the `code` package on every install.
Fetching the vendor's repofile at build time (upstream's route) means inheriting whatever
verification policy Microsoft ships that day, unreviewed — which today is none; vendoring it
(divergence #2) is what makes the `gpgcheck=1` position ours to keep.

## 6. `git-credential-libsecret` shipped (Aurora-only otherwise)

**Upstream**: Aurora base ships `git-credential-libsecret`; Bazzite base does NOT, and
Bazzite-DX inherits the gap.

**Us**: `build_files/mx/35-git-tools.sh` installs `git-credential-libsecret` so git
authentication via the system keyring works out-of-the-box.

**Why it matters**: GUI password prompts via the keyring instead of typing/pasting HTTPS tokens
on each push — standard modern git auth on Linux desktops, a day-1 UX upgrade.

## 7. VSCode `update.mode=none` atomic-correct default

**Upstream**: bazzite-dx ships the same setting plus opinionated font (Cascadia Code) + theme
defaults; AmyOS goes further with formatOnSave + Hack Nerd Font + zsh terminal default and many
style choices.

**Us**: `system_files/etc/skel/.config/Code/User/settings.json` is just
`{ "update.mode": "none" }` — the atomic-correctness fix only, no font/theme/formatter opinion.

**Why it matters**: the fix is mandatory (VSCode's self-updater fights a read-only `/usr`); the
rest is the user's choice. In this project stylistic preferences stay with the user —
minimalism is the feature we optimise for.

## 8. `bcc-tools` shipped alongside `bcc`

**Upstream**: Aurora-DX (`build_files/dx/00-dx.sh:20`) and bazzite-dx
(`build_files/20-install-apps.sh:6`) install only `bcc` — the BPF Compiler Collection
**library** + Python bindings. The command-line tracing utilities (`execsnoop`, `opensnoop`,
`tcpconnect`, `biotop`, `runqlat`, etc.) live in `bcc-tools`, a separate ~2 MiB package that
neither distro installs.

**Us**: `build_files/mx/40-dev-cli-rpms.sh` installs both `bcc` and `bcc-tools`; the tools land
under `/usr/share/bcc/tools/<name>`.

**Why it matters**: "where's `execsnoop`?" is answered out of the box; on Aurora-DX or
bazzite-dx the user has to layer `bcc-tools` post-install. The 2 MiB cost is negligible.

## 9. `gh` pinned from the official release, checksum-verified

**Upstream**: bazzite-dx does not install gh at all; Fedora's package trails the upstream
release by several minor versions.

**Us**: `build_files/mx/41-dev-cli-pinned.sh` installs `gh` from GitHub's official release
tarball, pinned (`GH_VERSION=2.99.0`) and verified against the release's `sha256` checksums
file before `install -m 0755` into `/usr/bin/gh`. `glab` follows the same pattern; `shellcheck`
and `shfmt` publish no checksum file, so their asset sha256 is pinned in the script itself
(`SHELLCHECK_SHA256`, `SHFMT_SHA256`, MEASURED 2026-09-01) and checked the same way. GitKraken
(`35-git-tools.sh`) is the third shape: an unsigned RPM behind a mutable URL, pinned by version
and sha256 in the script — the repo is its trust anchor, since upstream offers none.

**Why it matters**: a pinned, checksum-verified binary is a reproducible version with no
third-party repo to isolate — nothing for the enabled-state invariant to police. `gh` evolves
quickly (new commands, GitHub API features), and this dev-workstation use case leans on it
daily; the pin keeps it current with a one-line auditable bump.

## 10. Firefox from Mozilla's official RPM (vs. Flatpak)

**Upstream**: Bazzite installs Firefox as a Flathub flatpak (`org.mozilla.firefox`) via its
default-install list — consistent with its flatpak-first application model, which keeps browser
updates decoupled from the image cycle.

**Us**: Firefox via Mozilla's RPM repo (`build_files/mx/61-firefox-rpm.sh`, `mozilla.repo`
vendored `enabled=0`), plus the flatpak blocklisted from Flathub
(`build_files/mx/62-firefox-flatpak-exclude.sh`), plus cleanup hooks
(`15-bazzite-mx-firefox-flatpak-cleanup.sh` under both `system-setup.hooks.d/` and
`user-setup.hooks.d/`) that uninstall any pre-existing per-system/per-user flatpak Firefox on
next boot/login.

**Why it matters**:

- Native messaging, system fonts, system policies, and system keyring integration work
  out-of-the-box — flatpak Firefox needs socket workarounds (xdg-desktop-portal-gtk,
  file-system access permissions, etc.) for several of these.
- One source of truth for security updates (Mozilla's release cycle, no flatpak runtime
  drifting from the base image).
- No accidental "two Firefoxes installed" surprise from Discover's "Install Firefox" button.

**Which half actually defends the running system**: the `deny org.mozilla.firefox/*` line in
`/usr/share/ublue-os/flatpak-blocklist`, which `bazzite-flatpak-manager` hands to
`flatpak remote-modify --filter` — a denied ref cannot be installed or even listed. The sed
that drops `org.mozilla.firefox` from `/usr/share/ublue-os/bazzite/flatpak/install` has no
executable consumer in the image at all (MEASURED 2026-09-01: nothing under `/usr/bin`,
`/usr/libexec` or `/usr/lib/systemd` reads that path); it is the ISO/installer path's default
set, and it stays for images built into media.

## 11. Zero-maintenance third-party GPG keys

**Upstream**: neither bazzite-dx nor Aurora vendors a GPG key (re-verified on the local
checkouts, deep audit 2026-09-01: no `etc/pki` under either `system_files/`). Both point dnf
at a remote key: bazzite-dx adds its repos with `addrepo --from-repofile=<URL>`
(`20-install-apps.sh:94,106`), Aurora writes the repo file inline with
`gpgkey=https://packages.microsoft.com/keys/microsoft.asc` (`dx/00-dx.sh:96`), and dnf fetches
whatever key that URL serves at every build — trust-on-first-use, with no record of which key
was accepted.

**Us**: **1Password** (`build_files/mx/64-1password-key.sh`): the key is fetched at build
time too (`https://downloads.1password.com/linux/keys/1password.asc`) but landed as a file the
vendored `1password.repo` references locally (`gpgkey=file:///etc/pki/rpm-gpg/1password.asc`)
and checked against the pinned `KEY_FINGERPRINT` before it is trusted: a rotation is a
deliberate bump of that pin, never a silent swap.

**Why it matters**: the same zero-maintenance shape as upstream (no stale vendored key), with
the one thing upstream lacks — a fingerprint pin that makes a substituted key fail the build
(deep audit 2026-09-01, R3). Documented as part of the "third-party `.repo` is `enabled=0`"
isolation invariant.

## 12. Docker group + libvirt group via system-setup hook (with sysusers.d for docker)

Troubleshooting entry: gotcha #8 in [`gotchas.md`](gotchas.md).

**Upstream**: bazzite-dx-groups bundles its setup with several other concerns; Bazzite base has
no equivalent. More critically, both Aurora-DX and Bazzite-DX inherit the `docker-ce` scriptlet
gap: `groupadd --system docker` in the rpm postinstall scriptlet is SUPPRESSED on rpm-ostree
atomic systems (scriptlets are skipped to keep the OCI layer reproducible) — the `docker` group
never exists at runtime, the user is never added to it, and every `docker run` requires sudo.
Verified: neither ships a sysusers.d for docker.

**Us**: two-piece fix:

- `system_files/usr/share/ublue-os/system-setup.hooks.d/10-bazzite-mx-groups.sh` runs at first
  boot via the `ublue-system-setup.service` framework (idempotent via
  `libsetup.sh version-script`); appends `docker` + `libvirt` groups to `/etc/group` from
  `/usr/lib/group`, then `usermod -aG` for every wheel user.
- `system_files/usr/lib/sysusers.d/bazzite-mx-docker.conf`: a single `g docker -` line read by
  systemd-sysusers at sysinit.target (early in boot, before the group-adding hook) — creates
  the docker system group on every boot, exactly compensating the suppressed rpm scriptlet.

**Why it matters**: without this, `docker.socket` is enabled but the user can't `docker ps`
without `sudo`, and libvirt is similarly inaccessible — the same scriptlet gap the upstream DX
images inherit, closed here at the image layer.

**Privilege trade-off (deliberate)**: membership in `docker` is root-equivalent — any member
can start a container with `-v /:/host --privileged` and own the machine without a password
prompt — and `libvirt` grants `org.libvirt.unix.manage` without a password through Fedora's
own `50-libvirt.rules` (host raw disks attachable to a VM; libvirtd runs as root). Handing
both to every wheel user is the bazzite-dx pattern for `docker` (`bazzite-dx-groups:33`
adds every wheel member; upstream keeps `libvirt` behind the `ujust` opt-in in
`84-bazzite-virt.just:66`). bazzite-mx goes one step further and grants `libvirt` too, on
purpose: the images run on single-user personal machines where the wheel user is already the
administrator, and `libvirt` adds no privilege a `docker` member does not already hold
(refuter verdict, deep audit 2026-09-01). It is NOT the right default for a shared or
multi-user host: revoke per user with `sudo gpasswd -d <user> docker` (and `libvirt`), or set
`TARGET_GROUPS=()` in the hook and bump its `version-script` counter so the change re-runs.

## 13. Unified ujust reconcile (override removal + idempotent import) + `_pkg_layered` helper

Troubleshooting entries: gotchas #9 and #10 in [`gotchas.md`](gotchas.md).

**Upstream**: Bazzite-DX (`60-clean-base.sh:5`) and AmyOS (`install-apps.sh:107`) append their
`import` directive to Bazzite's master justfile **without** an idempotency check — duplicates
accumulate if the same script runs twice (e.g. during local pre-flights). Neither carries a
mechanism to override a same-named upstream recipe. The master justfile opens with
`set allow-duplicate-recipes := true`, so a duplicate name does not fail the parse: `just`
1.57.0 keeps the **first** definition it imported, and our imports are appended last (MEASURED
2026-09-01 in the shipped image — two imports defining the same recipe, order swapped, the
first wins both times). Without a removal, every override would silently lose to the upstream
copy.

**Us**: `build_files/mx/55-justfile-reconcile.sh` reconciles the ujust tree in two passes. (1)
**Surgical override removal** — for each recipe bazzite-mx replaces (`setup-sunshine`,
`setup-virtualization`, `install-jetbrains-toolbox`; manifest recipe→file), an awk state
machine strips the same-named recipe (with its decorating comments/attributes) from its
upstream `.just` file, hard-failing the build if a named recipe is absent so upstream drift
surfaces immediately. (2) **Idempotent import registration** —
`grep -qxF "$IMPORT_LINE" "$MASTER" || echo "$IMPORT_LINE" >> "$MASTER"` appends `import`
directives for both `95-bazzite-mx.just` and `96-bazzite-mx-overrides.just` only if absent, so
re-runs are side-effect-free. The two files split by role: `95-bazzite-mx.just` holds net-new
recipes (`install-1password`, `reset-repos`, `setup-msi`, `_pkg_layered`);
`96-bazzite-mx-overrides.just` holds the recipes that override an upstream same-named one.
`95-bazzite-mx.just` ships a `_pkg_layered` helper recipe that checks rpm-ostree overlay layer
membership (not `rpm -q`, which sees base-image packages too) and returns `yes`/`no` on stdout
rather than via exit code — `just` always emits
`error: Recipe X failed on line N with exit code 1` when a sub-recipe exits non-zero, even
inside the caller's `if`; the stdout-as-boolean pattern keeps `install-*` output clean.

**Why it matters**: overriding an upstream recipe without renaming it needs the upstream copy
gone — first-import-wins, and ours is last — and the drift guard turns a silent upstream rename
into a build failure instead of a stale override. Clean recipe UX, no spurious "error" lines on
re-run, and a reusable layering-check helper for any future `install-*` recipe.

## 14. VSCode extensions hardened against libsetup.sh state-before-body race

Troubleshooting entry: gotcha #11 in [`gotchas.md`](gotchas.md).

**Upstream**: Bazzite-DX's vscode-extensions hook carries the same race, benign in their case —
no failure mode there is as sensitive as ours; Aurora-DX avoids it by writing state at the END
of a custom libexec (no libsetup.sh).

**Race**: `libsetup.sh::version-script` writes the versioned state file BEFORE the hook body
runs. Under `set -euo pipefail`, a single failed command (transient marketplace timeout,
missing skel file, …) aborts the hook AFTER the state is committed → next login skips the hook
→ silent permanent disable.

**Us**: in `11-bazzite-mx-vscode-extensions.sh` every `code --install-extension X` carries
`|| true` so failure is benign and the hook completes (state correctly reflects "I tried");
source paths (`/etc/skel/.config/Code/User/settings.json`) are guarded with `[ -e ... ]` so a
future skel removal doesn't trigger the trap.

**Why it matters**: a one-time login glitch (network blip fetching from the marketplace) would
otherwise silently disable the hook forever — the 3 expected extensions never auto-install and
the user never learns why.

## 15. `gparted` ships as the GUI partition tool

**Upstream**: Bazzite **removes** `kde-partitionmanager` from its KDE base and ships GNOME
Disks (`gnome-disk-utility`) in every image instead (commit `0eab29c5` "Use gnome-disk in all
images"; `Containerfile:405` installs it, `:435` removes partitionmanager — re-verified on the
local checkout, deep audit 2026-09-01). GNOME Disks covers mounting, formatting and SMART; it
does not resize, move or copy partitions. Bazzite's ISO installer hook installs gparted only
into the live ISO environment.

**Us**: `build_files/mx/60-desktop-apps.sh` ships `gparted` (~9 MiB) beside GNOME Disks as the
full partition editor. Provenance reinforced by AmyOS, which ships gparted in their DX-style
list.

**Why it matters**: a daily-driver workstation needs to resize and move partitions (dual-boot
reshuffles, NTFS volumes), and GNOME Disks stops short of that; discovering the gap at the
moment of need means dropping to terminal `parted` or rebooting from USB.

## 16. Sunshine reintegrated as system RPM (vs. Bazzite's flatpak recipe)

**Upstream**: Bazzite shipped Sunshine as a system RPM from the `lizardbyte/beta` COPR until
commit `079fa8ad` (2026-03-26), then removed it citing "numerous ignored issues about their
stable repo not supporting Fedora 43 these last 6 months" — a reasonable call given the
packaging state they faced. The replacement `setup-sunshine` recipe went through a Homebrew
phase (commit `aa6ec9da`) and is flatpak-flavored since commit `e05b27f8` (2026-05-22):
`flatpak install --system -y dev.lizardbyte.app.Sunshine`, with brew surviving only in the
Deck-oriented `enable-beta` path.

**Us**: `build_files/mx/65-sunshine.sh` installs Sunshine as a system RPM via the community
`pvermeer/sunshine` COPR — the "Layer from Community COPR" method recommended by
[docs.bazzite.gg/Advanced/sunshine](https://docs.bazzite.gg/Advanced/sunshine/). The COPR
(spec: [PVermeer/copr_sunshine](https://github.com/PVermeer/copr_sunshine)) is maintained
explicitly for Fedora, tested on Fedora and Bazzite, and carries a package for every major
Fedora release — the docs' comparison table flags the official `lizardbyte/stable` COPR as
"inconsistent builds for Fedora releases" that can block system updates. Two pieces:

1. `copr_install_isolated "pvermeer/sunshine" "sunshine"` — the same isolated-COPR pattern used
   for `ublue-os-libvirt-workarounds`. The rpm name is lowercase `sunshine`, and the package
   itself ships `%caps(cap_sys_admin,cap_sys_nice+p)` on `/usr/bin/sunshine`, so KMS-based
   capture works with no build-time `setcap` step (a cap the lizardbyte packages omit; without
   it Sunshine falls back to a slower PipeWire portal path). The cost of that convenience: a
   compromised Sunshine process holds `CAP_SYS_ADMIN` (the catch-all root-like capability)
   for the user running it, where the flatpak runs inside a sandbox with no capability at all.
   Accepted because the unit is opt-in and the machines are single-user; not the right trade
   for a shared host.
2. `systemctl --global disable app-dev.lizardbyte.app.Sunshine.service` — defense-in-depth
   (Aurora pattern) against a preset enabling the unit: the package's `%systemd_user_post`
   honours presets and its drop-in adds gnome-session/xdg-desktop-autostart `[Install]`
   targets; opt-in via `ujust setup-sunshine enable`.

Recipe override (`setup-sunshine` in
`system_files/usr/share/ublue-os/just/96-bazzite-mx-overrides.just`, with the upstream copy
surgically removed from `82-bazzite-sunshine.just` by
`build_files/mx/55-justfile-reconcile.sh`): our RPM-flavoured recipe manages
`app-dev.lizardbyte.app.Sunshine.service` (the COPR-shipped user unit, with the spec-guaranteed
alias `sunshine.service`) via `systemctl --user enable --now`, in place of Bazzite's
flatpak-flavoured recipe. Announcement suppression: the build `rm`s
`/usr/share/ublue-os/announcements/sunshine-brew.msg.json` — its "Sunshine will soon be
removed" message is permanently misleading with RPM integration.

The `virtual-monitor` action is ported from upstream (bazzite `55e6e852`, KWin-only): the
helpers `sunshine-start-vmon` / `sunshine-stop-vmon` ship byte-identical in
`system_files/usr/libexec/` (their runtime dependencies — `krfb-virtualmonitor`,
`kscreen-doctor`, `jq` — verified present in the base image, 44.20260802), and the recipe
function keeps upstream's flatpak and native config branches, the native one applying on the
RPM install. Two upstream defects ship verbatim under that byte-fidelity (verified against
upstream origin/main, 2026-08-22): `sunshine-stop-vmon` loses `$output` in its `| while read`
subshell, so the restore writes an empty `output_name =` into `sunshine.conf` (benign —
Sunshine falls back to its default output), and both helpers define a `NOMONCONF` variable
nothing reads. A third one is a security posture rather than a bug: `sunshine-start-vmon`
runs `krfb-virtualmonitor` with the public constant password `sunshinepass` on port 5905,
so while the virtual monitor is up anyone who can reach that port has a VNC view of it — and
firewalld is disabled on the fleet hosts (MEASURED 2026-09-01 on ldesktop-zrombi; neither the
base nor this repo touches it), so the port is reachable from the LAN. Nothing on the host
consumes that password (Sunshine captures the output through KMS, not VNC), so the exposure
lasts exactly as long as a streaming session; kept verbatim under the byte-fidelity rule, a
fix (a per-run random password) belongs upstream. The recipe function's ported `Fix Error
503` branch is OUR file instead, and its two defects (audited 2026-08-22: a write into
`$HOME/.config/environment.d/` with no `mkdir -p`, and a confirmation `echo` that truncated
the `.conf` suffix from the path it reported) are fixed here as a fourth deliberate deviation
(deep audit 2026-09-01). The other three deviations from upstream's function: the
kinoite/deck image-info gate is dropped (every bazzite-mx image is KDE on plain `bazzite`), the
unit is referenced via `$SUNSHINE_UNIT`, and the `daemon-reload` after the
`systemctl --user edit` runs in `--user` scope (upstream reloads the system manager after
editing a user unit).

**Why it matters**: the flatpak cannot carry `cap_sys_admin`, so it streams through the slower
PipeWire portal path instead of KMS capture; installed next to our build-time RPM it would also
duplicate the app. For this use case the RPM is already there, captures via KMS thanks to the
file caps the package ships, updates with the image via `bootc upgrade`, and works on a fresh
deployment without any user setup.

## 17. Rechunker enabled by default (vs. the AmyOS template's commented-out step)

**Upstream**: AmyOS (`build.yml:111-115`, the image-template lineage) ships the rechunker
step **commented out** (a pinned `ublue-os/legacy-rechunk` action behind "uncomment if you
want it") — a reasonable default for a template whose first build should stay cheap, but a
fresh fork publishes one giant overlay layer per build. Bazzite-DX runs its rechunker live
(`build.yml:171-185`, a buildah script over `raw-img` with the same `build-chunked-oci`
flags as ours), and Aurora's `just rechunk` recipe wraps `chunkah` (its `Justfile`), not the
`hhd-dev/rechunk` action. (Claims re-verified against the local upstream checkouts, deep
audit 2026-09-01.)

**Us**: rechunker enabled by default in `.github/workflows/reusable-build.yml` using bootc's
native `rpm-ostree compose build-chunked-oci`. Choice over `hhd-dev/rechunk`:

- No external action version pin to maintain — runs in-image, the version shipped is exactly
  what bazzite ships.
- Integrates cleanly with our cosign-by-digest signing (no re-tagging dance).
- `--bootc --max-layers 127 --format-version 2` matches Bazzite's internal pattern, maximising
  cross-image dedup with the base.

**Cost**: ~+15 min wall-clock on the 6-job matrix (~13-15 min per job, parallel).

**Why it matters**: a fresh-fork user copy-pasting the AmyOS/image-template step gets a rechunkless
image silently, discovering the gap via slow / non-resumable downloads or a
faster-than-expected GHCR quota burn. We surface the choice, default it on, and document the
trade-off here.

## 18. Full MSI laptop EC control — working module + GUI

**Upstream**: the Bazzite `-ogc` kernel ships an **in-tree `msi-ec.ko`** that is a stale
mainline snapshot; on recent MSI hardware it rejects the machine's EC firmware outright — e.g.
on a Katana 17 (`17L5EMS1.115`), `modprobe msi-ec` fails with *"Firmware version is not
supported"*. The kernel is built with `CONFIG_ACPI_EC_DEBUGFS` off, so `ec_sys` cannot load and
`/sys/kernel/debug/ec/` never appears — leaving any fan GUI without a backend. No control
application is shipped. Net result: fan modes, shift modes, cooler-boost, and fan curves are
**unavailable** on otherwise-supported MSI laptops — a niche upstream has no reason to
prioritise, and exactly the hardware this project is built for.

**Us**: two out-of-tree modules built at image-build time by a generic kmod builder
(`build_files/kmods/build-kmods.sh`) and installed into `updates/` (highest depmod priority,
overriding the stale in-tree copy with no override file):

- **`msi-ec`** from BeardOverflow upstream, pinned commit `d7fbbd8`
  (`build_files/kmods/msi-ec/source.env`, `build_files/mx/70-msi-ec.sh`) — the current driver
  that *does* whitelist recent firmware.
- **`acpi_ec`** from `saidsay-so/acpi_ec`, pinned tag `v1.0.4` / `75102ce`
  (`build_files/kmods/acpi_ec/source.env`, `build_files/mx/71-acpi-ec.sh`) — creates the
  root-only `/dev/ec` char device, the fallback backend MControlCenter uses when the `ec_sys`
  debugfs node is absent, carrying both fan-RPM reads and fan-curve writes.

Both modules are built **unsigned** (`build-kmods.sh` has no signing step; ublue's akmods
dual-signs every module it builds): with Secure Boot enabled they do not load — the constraint
is spelled out in the recipe's own comment (`95-bazzite-mx.just`).

The control GUI — **MControlCenter**, the app cited by msi-ec's own README — ships from the
`teackot/msi` COPR (`teackot-msi.repo` vendored `enabled=0`). Everything is wired into a single
opt-in recipe `ujust setup-msi enable|disable` (`95-bazzite-mx.just`): `enable` loads both
modules, persists autoload, and layers the GUI; `disable` reverses all three. No autoload ships
in the image.

**Why it matters**: out of the box on Bazzite, an MSI-laptop owner gets a fan controller that
silently won't load and no app to drive it. Bazzite MX makes fan modes, shift modes,
cooler-boost, the battery-charge threshold, and fan curves actually work, with a GUI — verified
on the maintainer's Katana 17. It stays **opt-in** (no autoload, no GUI layered by default) so
non-MSI hardware pays nothing, honouring the "no opinionated defaults" principle. Commits:
`21b2a77` (msi-ec), `144739b` (GUI), `9fa571e` (acpi_ec).

## 19. Cosign image signature as the only supply-chain artifact

**Upstream**: bazzite (`build.yml:410-559` @ `17e598c6`) and aurora
(`reusable-build.yml:185-435` @ `a6e3750f`) both generate an SBOM with syft, attach it to the
image with `oras`, and sign it; both also emit a build-provenance attestation via
`actions/attest-build-provenance`. Sensible for distros with a broad user base: third-party
consumers can run policy checks and vulnerability scans against the published SBOM.

**Us**: `.github/workflows/reusable-build.yml` signs each image by digest with cosign — the
whole supply-chain surface, by choice.

**Why it matters**: this image has one consumer, its maintainer. The cosign signature covers
the real need — the machine boots exactly what this repo built. SBOM and provenance
attestations serve third parties running policy or vulnerability scanning against published
metadata, an audience this project serves through the public build logs and this repo itself.
Each extra artifact is standing maintenance (syft/oras versions, attestation formats, more
signing surface) with no consumer on the other end; this entry records the decision so it is
not re-derived.

## 20. JetBrains Toolbox from JetBrains directly (vs. Bazzite's Homebrew cask)

**Upstream**: Bazzite's `install-jetbrains-toolbox` recipe (`82-bazzite-apps.just`) installs
via Homebrew — `brew install --cask jetbrains-toolbox-linux` from the `ublue-os/tap` — so the
Toolbox lands in the Homebrew Cellar and depends on the brew subsystem being provisioned.

**Us**: `install-jetbrains-toolbox` in
`system_files/usr/share/ublue-os/just/96-bazzite-mx-overrides.just`, with the upstream brew
recipe surgically removed from `82-bazzite-apps.just` by
`build_files/mx/55-justfile-reconcile.sh`. The recipe uses the non-brew method Aurora/Bluefin
originated (bluefin PR #397, matured in #2645 / aurora #581): it resolves the latest build from
the JetBrains data-services API
(`https://data.services.jetbrains.com/products/releases?code=TBA&latest=true&type=release`,
parsed with the base image's `jq`), downloads the Linux tarball, verifies it against the
published `sha256` checksum, installs it as `~/.local/share/JetBrains/ToolboxApp/`, and
launches it (the app self-manages its desktop entry and auto-updates). It runs as the user
(`$HOME`), no `sudo`. The recipe is re-runnable: every run installs the latest build over the
previous one (the old tree is removed and the versioned directory renamed whole — `mv dir/*`
onto an existing install dies on "Directory not empty"), and a `trap … EXIT` removes the
tmpfs-backed work directory on every exit path (verified 2026-08-20 on the 3.7.0.87111 tarball,
first run + re-run + failure path).

This is now a solo position, no longer a shared port: Aurora removed its tarball recipe on
2025-12-16 (`070c393f`, recipes moved to the `get-aurora-dev/common` image) and its current
`install-jetbrains-toolbox` is the same brew cask Bazzite uses
(`brew install --cask jetbrains-toolbox-linux`). The tarball layout the recipe relies on is
unchanged as of 3.7.0 (`jetbrains-toolbox-<build>/bin/jetbrains-toolbox`).

**Why it matters**: the Toolbox is a self-updating per-user app that JetBrains publishes as a
plain Linux tarball; installing it straight from JetBrains avoids depending on Homebrew, the
`ublue-os/tap`, and the Cellar for a single GUI app, and keeps it entirely in the user's home
where its own updater expects it. A checksum-verified download from the vendor is a
reproducible, auditable trust anchor with no third-party repo or brew subsystem to police.

## 21. NTFSPLUS shipped as an out-of-tree module

**Upstream**: Linux 7.1 merged **NTFSPLUS** — Namjae Jeon's from-scratch in-kernel NTFS
read/write driver, built on iomap, folios and delayed allocation, with a userspace fsck — as
`fs/ntfs/` under `CONFIG_NTFS_FS`. It is optional at build time and coexists with ntfs3 by
design (`fs/ntfs3/Kconfig`: `depends on !NTFS_FS || m`). The ogc kernel leaves it off:
`# CONFIG_NTFS_FS is not set` in `/usr/src/kernels/<kver>/.config`, no `ntfs.ko` anywhere under
`/usr/lib/modules/<kver>/`. An NTFS volume therefore mounts through ntfs3 (kernel) or ntfs-3g
(FUSE), and the newer driver is simply unavailable. Turning the symbol on means rebuilding the
kernel through ogc's `kernel-packages` and maintaining a kernel fork.

**Us**: a third out-of-tree module in the existing `kmod-builder` stage, on the same pattern as
the two EC modules — `build_files/kmods/ntfsplus/source.env` (author's own standalone tree
`namjaejeon/linux-ntfs`, pinned commit `8e679ed1`, main's merge of ntfs-next of 2026-08-30) and `build_files/mx/72-ntfsplus.sh`,
installing into `updates/fs/ntfs/` so a later ogc build that enables the symbol is overridden
by depmod priority. Two properties are specific to this module:

- Its kbuild fragment is gated on the kernel's own `CONFIG_NTFS_FS`, so the build produces
  nothing and still exits 0 unless the symbol is forced — hence the new optional
  `KO_BUILD_ARGS` key in `source.env` (gotcha #25).
- No autoload and no `ujust` recipe ship with it, unlike `msi-ec`: the kernel loads a
  filesystem module on demand at the first mount of its type.

The driver registers the filesystem type **`ntfs`** — a name `mount(8)` resolves through
`/sbin/mount.<type>` before it ever reaches the kernel, and ntfs-3g owns that helper for `ntfs`
(gotcha #26). `72-ntfsplus.sh` therefore deletes `/usr/sbin/mount.ntfs` and
`/usr/bin/mount.ntfs` (usrmerge makes the two paths one file), which is what puts the driver
within reach of every mount path that names a type: fstab lines, systemd `.mount` units,
`mount -t auto`, and udisks on removable media. The `ntfs-3g` package stays installed because
`libguestfs-appliance` requires it, and `mount.ntfs-3g` survives, so `mount -t ntfs-3g` names
FUSE explicitly. `ntfs3` is untouched and keeps serving `ntfs3` fstab lines.

Selecting `ntfs` where a volume used `ntfs3` preserves what the user sees, measured on
`ldesktop-matrix` (gotchas #27 and #28): both drivers take an object's mode from its WSL
metadata EA `$LXMOD` and agree bit for bit, both are case-sensitive by default, and the two
points where they differ — `uid=`/`gid=` precedence over `$LXUID`/`$LXGID`, and the DOS
read-only attribute — run permissive-only, so no object loses an access bit. The round trip is
lossless in both directions, which keeps a fallback to `ntfs3` a one-line fstab edit.

**Why it matters**: this is a dual-boot workstation whose Windows partition is mounted from
Linux daily. ntfs3 is the maintained-but-inherited driver; NTFSPLUS passes more of xfstests,
carries a real fsck, and is the direction the kernel's NTFS support is taking. Having it
selectable per volume — with ntfs3 still in place and ntfs-3g one mount type away — turns "wait
for the kernel to enable it" into a per-mount choice. The one path that changes without being
asked is udisks: removable NTFS media, which libblkid types as `ntfs`, mounts on the kernel
driver instead of on FUSE.

## 22. `vfio-off` is a complete revert of `vfio-on`

Troubleshooting entries: gotchas #29, #30 and #31 in [`gotchas.md`](gotchas.md).

**Upstream**: bazzite-dx's `84-bazzite-virt.just` — the recipe divergence #4 tracks — reverts
VFIO through a list of `rpm-ostree kargs --delete-if-present` arguments, and builds two of them
into shell variables as `--delete-if-present=\"$VAL\"`. Expanding a variable performs word
splitting but no quote removal, so those two reach `rpm-ostree` with literal `"` inside the
karg name and match nothing; since `--delete-if-present` is silent about a karg it does not
find, the run looks clean. They are exactly the two host-specific kargs, `vfio_pci.ids` and
`kvmfr.static_size_mb`. `vfio_pci.ids` additionally goes undetected whenever it sits last on
the karg line, because the `sed` that extracts it requires whitespace after the value.
`vfio-on` calls `rpm-ostree initramfs --enable` — the only `initramfs` call in the file, with
no counterpart anywhere — which also discards any initramfs arguments the host had. Finally
`vfio-off` deletes two files with a plain `rm`, one of them written by no current recipe.

**Us**: five deviations inside the VFIO blocks, so that `vfio-on` followed by `vfio-off`
returns the same kargs, the same files and the same initramfs setting:

1. **Array-built removal list** — `KARG_ARGS=(…)` expanded as `"${KARG_ARGS[@]}"`, so every
   argument carries its quoting from where it is written.
2. **Order-independent detection** — `rpm-ostree kargs | tr ' ' '\n'` plus an anchored
   `grep '^vfio_pci\.ids='`, replacing the position-sensitive `sed`/`awk`/`grep` chain.
3. **`rm -f`** on both paths, so a host that never had `/etc/dracut.conf.d/vfio.conf` does not
   read a `No such file or directory` mid-cleanup as a failed revert.
4. **No `initramfs --enable` in `vfio-on`** — nothing in the recipe writes
   `/etc/dracut.conf.d`, so a local regeneration has no VFIO input to consume, while
   `force_drivers` in `/usr/lib/dracut/dracut.conf.d/80-vfio.conf` already bakes the modules
   into the image initramfs. Removing the call is what makes a counterpart unnecessary.
5. **No `rd.driver.pre=vfio-pci` karg in `vfio-on`** — that same `force_drivers` line writes
   `etc/cmdline.d/20-force_drivers.conf` inside the initramfs, which supplies
   `rd.driver.pre=vfio vfio_iommu_type1 vfio_pci` on its own. `vfio-off` keeps deleting the
   karg, since hosts set up by an earlier version of the recipe carry it.

The `virt-on` branch additionally reconciles what an earlier version of this recipe left on a
host: the `kvm.ignore_msrs` / `kvm.report_ignored_msrs` kargs, superseded by the module options
of divergence #4, and an argument-less initramfs regeneration — the exact shape the old
`vfio-on` produced. A regeneration carrying custom arguments was configured for the host's own
reasons and is left alone. `virt-on` is the branch that reaches both kinds of host, since one
keeping its VFIO setup never runs `vfio-off`.

Measured on `ldesktop-matrix` (bazzite-mx 44.20260802, `nvidia-open`), capturing
`rpm-ostree kargs`, the initramfs state and the two paths before `vfio-on` and again after
`vfio-off`: the pre-fix recipe left `kvmfr.static_size_mb=128` and
`vfio_pci.ids=10de:2504,10de:228e` behind and turned `["--hostonly", "--no-hostonly-cmdline"]`
into `[]`; the current one diffs identical to the baseline. Both `virt-on` reconcile branches
were exercised, the skip and the disable.

**Why it matters**: an incomplete revert of a passthrough setup is the failure that costs a
boot. A host whose GPU stays bound to `vfio-pci` comes back up without that GPU, and the karg
that did it was reported as removed. The initramfs half is quieter and longer-lived: every
later `rpm-ostree upgrade` pays a multi-minute regeneration traceable to a VFIO setup reverted
months earlier.

## 23. Rootful CI build and unverified base pulls (vs. upstream's 2026-08 refactors)

**Upstream**: image-template `b9783f6` moved the whole build/rechunk/push chain to rootless
podman/buildah (`build-chunked-oci --rootfs` + graphroot bind mount, no `sudo` in any step;
bazzite `033a18fb` followed), and aurora `a925e026` installs a `sigstoreSigned`
containers-policy on the runner so every pulled base image is signature-verified before the
build consumes it.

**Us**: the build jobs keep `sudo` buildah/podman and pull `ghcr.io/ublue-os/*` bases verified
by digest pinning alone (`UPSTREAM_DIGEST` resolved once and passed as a build arg). Both
upstream refactors are recorded here as the direction to take when the CI is next reworked,
deliberately deferred on 2026-08-21: the pipeline is green and signed end-to-end
(sign-before-publish, digest-copied alias tags, post-publication verify job with a negative
control), and each refactor is an invasive change to a working chain with marginal immediate
benefit. Revisit when a rootful-specific failure appears or upstream retires the rootful path.
The cosign pin moved to the 3.x line on 2026-09-01 (v3.1.3, the version bazzite-dx `a0f3842`
runs) with the pairing this note demanded: `--use-signing-config=false` alongside the
`--new-bundle-format=false` that was already there — v3 defaults both ON, and the pairing
image-template `b6ae704` proved necessary.

## 24. `/usr/lib/sysimage/libdnf5/` emptied at the end of the build

**Upstream**: bazzite ships the directory as the build leaves it. Aurora `cf4bc197` (PR #2580,
2026-07-20) deletes its contents in `clean-stage.sh`: every file there changes on every build
(timestamps, package versions, the transaction history), so the `libdnf5` package's chunk is
unique per build and every `bootc upgrade` re-downloads it although nothing a user cares about
changed.

**Us**: aurora's line adopted in `build_files/shared/clean-stage.sh` — ~600 KB per upgrade
(`nevras.toml` 89 KB, `packages.toml` 66 KB, `transaction_history.sqlite` 434 KB, MEASURED
2026-09-01 on `localhost/bazzite-mx:preflight`), plus a second payoff that is ours alone: the
transaction history was the second sqlite database `build.sh` step 4 had to rewrite onto a
fresh inode against the runner's writeback loss (gotcha #34), and the one whose 4 MiB
uncheckpointed WAL the vacuum existed to fold in. Not shipping it retires that guard and its
cold probe; `check-image-integrity.sh` section 3 asserts the directory is empty instead, so a
silently reverted delete cannot leave the database shipped and unguarded.

**Why it matters**: smaller `bootc upgrade` deltas for a file nobody reads — `dnf5 history` is
not the right tool on an atomic image, and the build log carries the same information — and one
fewer artefact on the torn-writeback surface.

## 25. The image trusts its own signatures

**Upstream**: the base installs `ublue-os-signing` 0.5, which ships `/etc/pki/containers/
ublue-os.pub`, `registries.d/ublue-os.yaml` (`use-sigstore-attachments: true`) and a
`sigstoreSigned` scope for `ghcr.io/ublue-os` in `/etc/containers/policy.json`, with
`default: reject` and a docker `""` catch-all of `insecureAcceptAnything`. Aurora's
`.github/setup-runner-keys.sh` applies the same shape on the CI runner for its base pulls. A
downstream image inherits all of it and none of it applies to the downstream's own registry
scope: `00-image-info.sh` stamps `ostree-image-signed:docker://ghcr.io/matrixdj96/…` as the
image-ref (what `ujust rebase-helper` offers), yet a host on that transport pulled our image
through the `""` catch-all, unverified, and reported it verified. `ostree-unverified-registry`
(what our hosts run today) never consults the policy at all: in ostree-ext it maps to
`SignatureSource::ContainerPolicyAllowInsecure` (`crates/ostree-ext/src/container/mod.rs:256`),
and `ostree-image-signed` maps to `ContainerPolicy`, which refuses outright when the policy
default is `insecureAcceptAnything` (`store.rs:943`) — read from the bootc sources on 2026-09-02.

**Us**: `build_files/mx/01-image-signing.sh` installs the repo's `cosign.pub` as
`/etc/pki/containers/matrixdj96.pub` (the Containerfile ships the root key through the `ctx`
stage, so the key has one source), ships `registries.d/matrixdj96.yaml` from `system_files/`,
and adds the `ghcr.io/matrixdj96` scope with `jq`, written to a sibling file and `mv`'d over
(gotcha #34). The script asserts the base default is still `reject` and that the `ublue-os`
scope survived the merge; the smoke test re-asserts every piece on the built image, byte-compares
the installed key with `/ctx/cosign.pub`, and the cold integrity check probes the three files for
a NUL tail. Deep audit 2026-09-01, root R2(b).

**Why it matters**: a host switched to the signed transport once,

```bash
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/matrixdj96/bazzite-mx:stable
```

(or `bootc switch --enforce-container-sigpolicy ghcr.io/matrixdj96/bazzite-mx:stable`) has
every later upgrade rejected unless the manifest carries a signature by our key: a registry
account takeover or a re-pushed tag stops at the pull. The chicken-and-egg is real and
one-time: the policy must already be on the host for the first signed pull, so the switch is
made from a deployment that ships it. Hosts staying on `ostree-unverified-registry` keep the
old behaviour — nothing breaks, nothing is verified — and `podman pull ghcr.io/matrixdj96/…`
is verified on every host that ships the policy, regardless of transport.

## How to extend this list

When adding a new phase, ask: **does this project's use case call for something different from
upstream `bazzite-dx`?** If yes, document the divergence here with: the introducing commit
hash, the upstream behaviour diverged from (`file:line` reference) and — when known — why it
makes sense in upstream's own context, our solution (`file:line` reference), and why it matters
for an end user. Avoid soft divergences (formatting, naming, "I prefer X"); a divergence worth
recording fixes a concrete bug for our use case, ships a clearly in-scope package upstream's
audience doesn't need by default, hardens the supply chain, or reduces maintenance (e.g.
zero-cost auto-update of keys).
