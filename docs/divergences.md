# Divergences from Bazzite

What this image changes over its base, one entry per feature. A change enters only when
upstream does not cover it, it needs the image layer, a host that runs the image uses it and it
ships a smoke test. Each entry says what the image does, why, where the claim comes from and
which files carry it; the guards themselves live in the build script and its test.
[`gotchas.md`](gotchas.md) holds the surprises this project probed, each with its date.

## Three flavours, one recipe

Bazzite publishes one image per graphics stack: `bazzite` for AMD and Intel,
`bazzite-nvidia-open` for the open kernel modules and `bazzite-nvidia` for the closed driver.
This image follows all three, and the base image is the only difference between them. A host
reaches the changes below only through an image built on its own stack's base. The recipe
therefore stays one file with `BASE_IMAGE` as its single variable, and `resolve-base.sh` maps a
flavour to a base image and pins it to a digest. The closed-driver base carries a kernel of its
own, so the kmod-builder stage compiles the out-of-tree modules against the kernel each base
ships.

Every enumeration of the three images is literal: `PACKAGES` and `FLAVOURS` in
`.github/scripts/lib.sh`, the build matrix, the retention list and the recovery signer name
them one by one; the watcher and `resolve-base.sh --digests` loop over `FLAVOURS`.
`release-tag.sh` probes every package for taken tags. A package that was never published
answers `name unknown` to a logged-in probe, which the version job reads as "no tags". Any
other registry error fails the probe closed.

Files: `Containerfile`, `.github/scripts/resolve-base.sh`, `.github/scripts/lib.sh`,
`.github/scripts/release-tag.sh`, `.github/scripts/watch-upstream.sh`.

## Signing trust for our own images

Bazzite verifies `ghcr.io/ublue-os/*` against its own key and says nothing about downstream
images. A host that follows `ghcr.io/matrixdj96/*` over `ostree-image-signed:docker://` needs
the scope, the key and the sigstore attachment stanza inside the image it boots, or the first
signed pull has nothing to verify against. The build installs `cosign.pub` at
`/etc/pki/containers/matrixdj96.pub` and writes one `sigstoreSigned` scope with
`signedIdentity: matchRepository`, which leaves the tag free: the host follows `:stable` while
the signature sits on the digest. Sources: containers-policy.json(5),
containers-registries.d(5).

Files: `build_files/11-image-signing.sh` and its test, `cosign.pub`,
`system_files/etc/containers/registries.d/matrixdj96.yaml`.

## Hook framework: ublue-setup-services

The base ships no `system-setup.hooks.d` dispatcher. Two features here need a step that
converges at every boot: the group memberships the container runtime and libvirt need, and the
VS Code extensions of each account. `ublue-setup-services` comes from the COPR
`ublue-os/packages`, the way bazzite-dx installs it
(`bazzite-dx/build_files/20-install-apps.sh`) and enables it
(`bazzite-dx/build_files/40-services.sh`). Only the system unit is enabled here;
`ublue-user-setup.service` is enabled `--global` by the IDE feature, the first one with a user
hook. Our hook converges instead of stamping a version. bazzite-dx gates the same work behind
libsetup's `version-script`
(`bazzite-dx/system_files/usr/share/ublue-os/privileged-setup.hooks.d/20-dx.sh`), which records
the run before the body executes: it never repeats a failed run and never reaches an account
created later.

Files: `build_files/20-setup-services.sh` and its test,
`system_files/usr/share/ublue-os/system-setup.hooks.d/10-bazzite-mx-groups.sh`.

## Docker CE

Bazzite ships podman only, and the hosts here run Docker for devcontainers and compose. The
pattern is bazzite-dx's (`build_files/20-install-apps.sh`), rewritten. The five packages of
https://docs.docker.com/engine/install/fedora/ come from a vendored repository with `enabled=0`
and `gpgkey=file://`, its fingerprint asserted before the first install. bazzite-dx instead
fetches the file at build time and disables it with a `dnf5 config-manager setopt`, a silent
no-op on a repository added from a file. `docker.socket` is enabled and `docker.service` left
to socket activation, `podman.socket` with it, and `podman-machine`, `podman-tui`,
`podman-compose` and `bcvk` come from Fedora in the same script.

Two host-level effects need the image layer. `iptable_nat` is listed in `modules-load.d` for
docker-in-docker, whose inner dockerd cannot load kernel modules itself
(devcontainers/features#1235, ublue-os/bluefin#2365). The `docker` group the packages' `%post`
creates is moved to `/usr/lib/group` by `95-clean-stage.sh`, where NSS resolves it through
`altfiles`. That relocation keeps `bootc container lint --fatal-warnings` green, its sysusers
check refusing a group line in `/etc/group`. The boot hook copies the line back and adds every
wheel member, which grants root-level privileges
(https://docs.docker.com/engine/install/linux-postinstall/), the bazzite-dx choice, kept
because the fleet's wheel users administer their own machines. One residual: the `%post` loads
an SELinux module only where `selinuxenabled` answers true, which it does not in a build
container, so hosts run without that AF_ALG denial.

Files: `build_files/21-container-runtime.sh` and its test,
`system_files/etc/yum.repos.d/docker-ce.repo`,
`system_files/etc/pki/rpm-gpg/RPM-GPG-KEY-docker-ce`,
`system_files/usr/lib/modules-load.d/ip_tables.conf`,
`system_files/usr/share/ublue-os/system-setup.hooks.d/10-bazzite-mx-groups.sh`.

## Virtualization and quickemu

Bazzite ships `edk2-ovmf` and the `kvmfr` module but no libvirt, QEMU or virt-manager: its
`setup-virtualization` recipe installs the virt-manager Flatpak and enables the monolithic
`libvirtd` per host. The hosts here run local VMs, so the stack belongs in the image, as an
explicit package list with weak dependencies off on the modular daemons Fedora 44's own preset
enables (https://libvirt.org/daemons.html). The build asserts `virtqemud.socket` enabled and
`libvirtd.service` disabled, so a preset change stops the build, and the virt-manager Flatpak
is denied through the base's Flatpak filter, the RPM being in the image.

Four smaller choices go with it. `ublue-os-libvirt-workarounds` from the same COPR handles the
`restorecon` of `/var/{lib,log}/libvirt` at boot, and a tmpfiles file recreates the `/var`
directories the packages ship, rpm-ostree's autovar mechanism not recovering directories a
build removed. The KVM options Bazzite adds as kernel arguments are set in `modprobe.d`
instead, `kvm` being a module in the ogc kernel. quickemu needs `mesa-demos`, which the base's
`exclude=mesa-*` filters out because Mesa comes from Terra. The build lifts that exclude for
that one package and proves no other `mesa-*` package moved. The `libvirt` group reaches wheel
members through the boot hook, like `docker`.

The recipe `setup-virtualization` replaces Bazzite's file of the same name. It reports status
and runs the kvmfr setup, bazzite-dx's helper with one fix: the bold codes its notice prints
are never set by `ujust.sh`, so our copy sets them. Not carried over: VFIO on and off, the
SPICE USB hot-plug udev rule, the `setfacl` on the home directory and the VFIO-Tools hook
download, each returning as its own recipe when a host needs it.

Files: `build_files/22-virtualization.sh` and its test, `build_files/lib/flatpak.sh`,
`system_files/usr/lib/modprobe.d/bazzite-mx-kvm.conf`,
`system_files/usr/lib/tmpfiles.d/bazzite-mx-virt.conf`,
`system_files/usr/share/ublue-os/just/84-bazzite-virt.just`,
`system_files/usr/libexec/bazzite-dx-kvmfr-setup`.

## Visual Studio Code

The RPM from Microsoft's repository, so the editor follows the image instead of updating itself
per user. bazzite-dx fetches Microsoft's `config.repo` at build time with `gpgcheck=0`
(`bazzite-dx/build_files/20-install-apps.sh`); here `vscode.repo` is vendored with the stanza
https://code.visualstudio.com/docs/setup/linux gives, the key ships in the image and its
fingerprint is asserted before the install. The skel `settings.json` sets `update.mode` to
`none`, which the editor's FAQ prescribes when a package manager owns the updates
(https://code.visualstudio.com/docs/supporting/faq).

The user hook seeds those settings for accounts that predate the image and installs the
containers and remote-ssh extensions when `~/.vscode/extensions/extensions.json` lacks them. It
runs at every login and keeps no version stamp, so an account created later is picked up, and
its check reads that file rather than spawning the editor.

Files: `build_files/30-ide.sh` and its test, `system_files/etc/yum.repos.d/vscode.repo`,
`system_files/etc/pki/rpm-gpg/RPM-GPG-KEY-microsoft`,
`system_files/etc/skel/.config/Code/User/settings.json`,
`system_files/usr/share/ublue-os/user-setup.hooks.d/11-bazzite-mx-vscode-extensions.sh`.

## Git tools

GitKraken as an RPM in the image rather than a Flatpak, the owner's choice, plus
`git-credential-libsecret` from Fedora. GitKraken publishes one fixed URL,
https://release.gitkraken.com/linux/gitkraken-amd64.rpm, which redirects to whatever release is
current, so nothing is pinned. The RPM carries no OpenPGP signature and no scriptlets, so the
build checks its payload digests with `rpm -K --nosignature` and installs it with
`--no-gpgchecks` for that one local file. Its only dependency, `libXScrnSaver`, is in the base.

Files: `build_files/31-git-tools.sh` and its test.

## Command-line tools

`gh`, `glab`, `ShellCheck` and `shfmt`, plus the thirteen further packages `32-cli-rpms.sh`
installs in one transaction: the tracing and profiling set (`bcc`, `bcc-tools`, `bpftop`,
`bpftrace`, `iotop-c`, `nicstat`, `numactl`, `sysprof`, `trace-cmd`) and `android-tools`,
`ccache`, `flatpak-builder` and `ripgrep`. All are Fedora 44 packages and none is in the base;
bazzite-dx and aurora carry most of the same names. Fedora's `shfmt` is the release CI and the
edit hook format with, so image, hook and CI agree on the formatter and no formatting diff is
meaningless ([`conventions.md`](conventions.md)).

Files: `build_files/32-cli-rpms.sh` and its test.

## mise

`mise` manages per-user language runtimes. Its binary comes from the COPR its own documentation
names (https://mise.jdx.dev/installing-mise.html), so it is the same on every host and needs no
first-login install. The repository is vendored with `enabled=0`, the project key ships in the
image and its fingerprint is asserted before the install.

`/etc/profile.d/mise.sh` runs `mise activate bash` in interactive bash, which reaches non-login
shells too because Fedora's `/etc/bashrc` sources `profile.d`. The skel
`~/.config/mise/config.toml` names node lts, python 3.14, java temurin-21 and dotnet 10; the
runtimes themselves are installed per user with `mise install`, never in the image. Other
shells activate mise themselves and the package ships their completions.

Files: `build_files/33-mise.sh` and its test, `system_files/etc/profile.d/mise.sh`,
`system_files/etc/skel/.config/mise/config.toml`, `system_files/etc/yum.repos.d/mise.repo`,
`system_files/etc/pki/rpm-gpg/RPM-GPG-KEY-copr-jdxcode-mise`.

## Desktop applications

**Firefox.** Bazzite removes `firefox` and `firefox-langpacks` in favour of the Flatpak. The
RPM is back because of 1Password's browser integration: native messaging goes through
`/opt/1Password/1Password-BrowserSupport`, a host binary a sandboxed Firefox does not reach out
of the box. The Flatpak is denied through the mechanism Bazzite already runs at every boot,
`bazzite-flatpak-manager` passing its blocklist to `flatpak remote-modify --filter` on Flathub
(flatpak-remote-add(1)), and a host that already has it keeps it. **gparted** comes from
Fedora, where Bazzite ships `gnome-disk-utility` and gparted only on the live ISO.
**teams-for-linux** is deliberately absent: `flatpak preinstall` synchronises, so removing an
entry later would uninstall the app (flatpak-preinstall(1)); its install command is printed by
`ujust migrate apply` and listed in [`migration.md`](migration.md).

**1Password** comes from the vendor's repository, the stanza of
https://support.1password.com/install-linux/ vendored with `enabled=0` and the key from
https://downloads.1password.com/linux/keys/1password.asc, whose fingerprint the vendor's page
prints as well. `repo_gpgcheck=1` stays because the repository publishes
`repodata/repomd.xml.asc`; the package's own `.repo` comments that out for a dnf4-era bug
(bugzilla 1768206). Installing at build time rather than layering on the host is what keeps
`bootc status` compatible. Its `%post` needs three answers. It rewrites the `.repo` file with
`enabled=1`, so the build reinstalls the vendored copy and asserts it byte for byte. It fills
the polkit owner annotation from the first ten UID ≥ 1000 users of `/etc/passwd`, and a build
has no such user. The annotation therefore ships empty, and the build fails if one were
rendered there. Nothing is lost: polkit lets a process check the authorization of another
process of the same user without it (polkit(8)). It creates two groups without `--system`,
which in a build would take the gids of a host's first human users, and a system gid is no
answer either since the app rejects a BrowserSupport whose group id is below 1000
([`gotchas.md`](gotchas.md)); the build creates them first with the fixed gids NixOS reserves.

**The `/opt` payload.** The image's `/opt` is a symlink to `var/opt`, and `/var/opt` is created
on a host by rpm-ostree's own tmpfiles line but does not exist in a build, so an RPM unpacking
under `/opt` dies in cpio. `80-fix-opt.sh` moves every `/var/opt/<name>` to
`/usr/lib/opt/<name>` and writes one tmpfiles `L+` line per directory, so the `/opt/...` paths
baked into the application resolve on the host. This is bootc's own guidance for `/opt` content
and the pattern bazzite-dx uses, rewritten so the checks run before the first move.

Files: `build_files/40-desktop-apps.sh` and `build_files/80-fix-opt.sh` with their tests,
`build_files/lib/flatpak.sh`, `system_files/etc/yum.repos.d/1password.repo`,
`system_files/etc/pki/rpm-gpg/RPM-GPG-KEY-1password`.

## Sunshine

Bazzite dropped its Sunshine RPM, and its `setup-sunshine` installs the Flatpak per host
(`bazzite/system_files/desktop/shared/usr/share/ublue-os/just/82-bazzite-sunshine.just`). The
RPM is in the image because the Flatpak cannot do what the fleet uses it for: Flatpak does not
support KMS capture, which needs elevated privileges (LizardByte/Sunshine,
`docs/getting_started.md`). The package comes from the COPR the Sunshine docs name, vendored
with `enabled=0` and the file's `priority=1` dropped, which would otherwise let the repository
override Fedora's packages on a host that enabled it. Its `/usr/bin/sunshine` carries
`cap_sys_admin,cap_sys_nice=p`, which KMS capture needs and which also means a compromised
process holds `CAP_SYS_ADMIN` for the user running it, accepted because the unit is opt-in and
the hosts are single-user.

Streaming stays opt-in: the RPM's user unit is disabled for every user with `systemctl --global
disable`, asserted after the install rather than assumed from the presets, and enabled per user
by the recipe. Bazzite's announcement telling users of that unit to reinstall from the Portal
is removed. The recipe `setup-sunshine` replaces Bazzite's with `status`, `enable`, `disable`,
`portal` and `virtual-monitor`, the last being Bazzite's "Virtual Monitor" app rewritten for
the RPM. Not carried over: the install, update and uninstall paths, the RPM following the
image, and the Deck and Homebrew branches, the fleet having no Deck image. The "Fix Error 503"
switch is a KWin permission bypass, and returns as its own step if a host needs it.

Files: `build_files/41-sunshine.sh` and its test, `system_files/etc/yum.repos.d/sunshine.repo`,
`system_files/etc/pki/rpm-gpg/RPM-GPG-KEY-copr-lizardbyte-stable`,
`system_files/usr/share/ublue-os/just/82-bazzite-sunshine.just`.

## KDE defaults

Four per-user defaults. They reach existing accounts only from the image, which is why they
are here and not in a recipe.

Two of them are Plasma update scripts under the shell package's `contents/updates/`, the
mechanism Plasma itself and Bazzite use for one-shot per-user defaults: plasmashell runs every
`.js` there once per user and records it in `~/.config/plasmashellrc` (KDE developer
documentation, Plasma scripting), reaching new accounts after the default layout and existing
ones at their next start. An autostart entry with a per-user stamp file would need a wait for
plasmashell on the session bus; this form needs neither. A
JavaScript error is only a warning in the journal, and the script is still marked performed.
The CI lint job therefore checks the files with `node --check`, there being no JavaScript
engine in the image. The first sets `showSeconds=2` on every digital clock that still has the
upstream default, leaving a clock the user set to never alone. The second gives every screen
without any panel a bottom panel copying the primary's geometry and widgets, minus the system
tray, a second tray applet spawning a duplicate containment. A screen that already carries a
panel is skipped. A first login with one screen adds nothing and the script is still marked
performed, so `ujust setup-panels` evaluates the same file through
`org.kde.PlasmaShell.evaluateScript`.

The other two are skel files for Windows-style copy and paste. Konsole gets `edit_copy` on
`Ctrl+C; Ctrl+Shift+C` through a `sessionui.rc` whose `version="1"` is below Konsole's own, so
KXmlGui merges only its `ActionProperties`; Konsole disables that action while nothing is
selected, so Ctrl+C still interrupts the shell. PowerShell is not in the image, and the skel
profile applies to a pwsh the user installs, binding the two keys through `wl-copy` and
`wl-paste` because PSReadLine's own clipboard functions need xclip on Linux.

Files: `build_files/45-kde-defaults.sh` and its test, the two scripts under
`system_files/usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/`,
`system_files/etc/skel/.local/share/kxmlgui5/konsole/sessionui.rc`,
`system_files/etc/skel/.config/powershell/profile.ps1`, and the recipe `setup-panels` in
`system_files/usr/share/ublue-os/just/95-bazzite-mx.just`.

## MSI laptop: kernel modules and MControlCenter

The fleet's laptop is an MSI machine whose fan curves, shift modes, keyboard backlight and
battery thresholds are reachable only through its embedded controller. Two out-of-tree modules
and a per-host install cover it, and nothing here loads on any other machine. **msi-ec**
(BeardOverflow/msi-ec) is pinned to a commit of `main`. The ogc kernel builds its in-tree copy,
but that copy prints no version and lags the project. Ours lands under `updates/`, which depmod
searches before `kernel/` (kmod's `tools/depmod.c`). **acpi_ec** (saidsay-so/acpi_ec) creates
the root-only character device `/dev/ec` that MControlCenter falls back to for fan speeds when
`/sys/kernel/debug/ec/ec0/io` is absent, and it is absent: the ogc kernel leaves
`CONFIG_ACPI_EC_DEBUGFS` unset.

The builder is the base image itself, not an akmods carrier, Bazzite installing `kernel-devel`
for its kernel and versionlocking it. The kernel's build system is called directly rather than
the modules' own `make`, which targets `/lib/modules/$(uname -r)/build`, the runner's kernel
and not the image's. Both modules are unsigned, the kernel setting `CONFIG_MODULE_SIG_ALL=y`
but not `CONFIG_MODULE_SIG_FORCE`. They load with a taint when Secure Boot is off and are
refused by lockdown when it is on, and the recipe prints that reason when modprobe fails. MOK
enrolment is out of scope. Nothing loads them at boot, since every other host never touches
them. `ujust setup-msi enable`, gated on the DMI vendor `Micro-Star`, writes the modules-load
file and loads them now. `verify-host` fails on any other modules-load file naming them. They
stay out of the initramfs by design, and this image replaces no in-tree module.

MControlCenter (dmitry-s93/MControlCenter) is installed per host from the tarball of its latest
GitHub release, with no pin, being neither on Flathub nor shipped as an AppImage. Upstream's
installer puts the GUI, the root helper, the D-Bus policy and the activation file under `/usr`,
which on a bootc host is the image. Ours puts everything under `/usr/local` and
`/etc/dbus-1/system.d`, both of which dbus-broker's launcher and `system.conf` already search.
The helper goes to `/usr/local/bin` and not to `libexec` because SELinux labels the former as
`bin_t` while `/usr/local/libexec` falls to `usr_t`. The privilege model is upstream's: the
helper runs as root and every local user may send to it, accepted on a single-user machine.

Files: `build_files/50-kmods.sh` and its test, `build_files/kmods/build-kmods.sh`,
`build_files/kmods/msi-ec/source.env`, `build_files/kmods/acpi_ec/source.env`,
`build_files/lib/kmod.sh`, `system_files/usr/libexec/bazzite-mx-msi-setup`, and the recipe
`setup-msi` in `system_files/usr/share/ublue-os/just/95-bazzite-mx.just`.

## NTFSPLUS as a per-host opt-in

NTFSPLUS is the from-scratch read/write NTFS driver on iomap and folios that Linux 7.1 carries
as `fs/ntfs`, written by Namjae Jeon, the author of exFAT and ksmbd. It and `ntfs3` coexist by
design (`fs/ntfs3/Kconfig`: `depends on !NTFS_FS || m`). The ogc kernel builds it off, so the
image builds the author's standalone packaging of the same code (`namjaejeon/linux-ntfs`),
pinned to a merge commit of `main`: `ntfs-next` is force-pushed and its tip may be mid-rework.
The module is `ntfs.ko` and registers the filesystem type `ntfs`: "ntfsplus" is the project's
name, never the module's nor the mount type's. Its kbuild fragment is gated on
`CONFIG_NTFS_FS`, so `source.env` forces the symbol on the make line
([`gotchas.md`](gotchas.md)).

The in-kernel `ntfs3` is the fleet's baseline and no host changes NTFS driver without its own
choice, so the image ships `blacklist ntfs` in `/usr/lib/modprobe.d/`. That stops the kernel
from loading the driver by alias at the first `mount -t ntfs`, while an explicit `modprobe
ntfs` still works. kmod reads `/etc/modprobe.d` first and skips a later file of the same name,
so a comments-only file of that name under `/etc` masks the blacklist
([`gotchas.md`](gotchas.md)). That file is the opt-in: `ujust setup-ntfsplus enable` writes it,
`disable` removes it, and `verify-host` and `migrate` read it. The build also removes the four
generic `mount.ntfs` and `mount.ntfs-fuse` links ntfs-3g installs. `mount(8)` hands any type
with a helper to it before the kernel sees the type, and `mount -i` has no fstab equivalent.
`mount.ntfs-3g` and `ntfsprogs` stay, so `mount -t ntfs-3g` remains the explicit FUSE route.

`ujust setup-ntfsplus enable` proves the driver before touching fstab: a loop image formatted
with `mkntfs`, mounted with `-t ntfs` and checked to report `ntfs` as its type, written to,
unmounted, remounted, checksum compared. Only then do the `ntfs3` rows of fstab become `ntfs`,
the type column alone and the options untouched. A backup, `daemon-reload`, `findmnt --verify
--fstab` and a remount of each rewritten volume follow, a busy volume keeping its driver until
the next boot. `disable` is the exact reverse. The probe exists because a module built for the
wrong kernel API dies at its first mount with vermagic and modinfo green, and fstab mounts fire
at boot before the journal is on disk ([`gotchas.md`](gotchas.md)). No mount is ever proven in
the build, there being no kernel to load into, so a pin bump takes the runtime proof on a
booted host. Recovery after a boot panic: boot the previous deployment and run `ujust
setup-ntfsplus disable`.

Files: `build_files/55-ntfsplus.sh` and its test, `build_files/kmods/ntfsplus/source.env`,
`system_files/usr/lib/modprobe.d/bazzite-mx-ntfsplus.conf`,
`system_files/usr/libexec/bazzite-mx-ntfsplus-setup`, and the recipe `setup-ntfsplus` in
`system_files/usr/share/ublue-os/just/95-bazzite-mx.just`.

## ujust recipes

Bazzite's `ujust` is `just` run on `/usr/share/ublue-os/justfile`, which imports every file
under `/usr/share/ublue-os/just/` by name and sets `allow-duplicate-recipes`. Seven recipes of
ours join it: `setup-panels`, `setup-msi`, `setup-ntfsplus`, `setup-dev`,
`install-jetbrains-toolbox`, `verify-host` and `migrate`.

`95-bazzite-mx.just` is appended as one more `import` line, the way bazzite-dx adds its own
file. With duplicate names across imports the earlier import wins ([`gotchas.md`](gotchas.md)),
so an appended import can never override a base recipe. A recipe of ours that carries an
upstream name therefore takes the upstream file's place, as `84-bazzite-virt.just` and
`82-bazzite-sunshine.just` do, each holding exactly the one recipe we replace. When the
upstream file holds other recipes too, the upstream recipe is cut out of it with its neighbours
proven unchanged. `00-prep.sh` records every base recipe file's recipe set before
`system_files` is copied. `70-justfile.sh` then refuses a replaced file whose set differs from
ours, an override whose recipe the base no longer has, and any name defined in two files.

`verify-host` answers whether a host is where the image expects it. The name is ours, after
Bazzite's `verify-image`, which only rewrites the transport for `ghcr.io/ublue-os`. `migrate`
brings a host to the state this image expects, in one pending deployment, with a confirmation
per mutating step and the reboot left to the user. It uses rpm-ostree rather than `bootc
switch`: rpm-ostree is visible, has a dry run and produces the same origin. What both check and
do is [`migration.md`](migration.md). `setup-dev` runs `mise ls` for status or `mise install`
after seeding the config from `/etc/skel`. `install-jetbrains-toolbox` replaces Bazzite's
Homebrew cask with JetBrains' documented Linux install: read the release feed, download the
tarball, compare its sha256 with the feed's checksum file, unpack and start it once. The build
of a Toolbox already unpacked there is read from the tarball's own `bin/build.txt` (the feed's
`build` field; measured 2026-09-05 on 3.7.2.87231), so a Toolbox of the same build is left
alone whoever put it there ([`gotchas.md`](gotchas.md)).

Files: `build_files/70-justfile.sh` and its test,
`system_files/usr/share/ublue-os/just/95-bazzite-mx.just`, and the helpers
`bazzite-mx-verify-host`, `bazzite-mx-migrate` and `bazzite-mx-jetbrains-toolbox` under
`system_files/usr/libexec/`, which share `system_files/usr/lib/bazzite-mx/host.sh`.

## CI: what differs from the family

How a change ships is [`workflow.md`](workflow.md), and the rule behind each choice is
[`conventions.md`](conventions.md). What follows is the delta against Bazzite, bazzite-dx and
aurora.

**A push never publishes.** Bazzite builds, rechunks, tests and pushes in one job gated on the
event (`bazzite/.github/workflows/build.yml`), where aurora takes `publish` as an input
(`aurora/.github/workflows/reusable-build.yml`). Here only the dispatched release workflow
passes `publish`. This repository is also the only one of the family that proves the signing
secret on every push to `main`. It is the only one that lints its scripts and workflows in CI
before the build.

**The artefact that ships is the one that is probed.** Bazzite runs goss on the chunked image
and is the only member of the family that tests what it ships
(`bazzite/.github/workflows/build.yml`). `check-image.sh` does the same with the tools the
image already has, and asserts on the artefact every label `image-labels.sh` wrote.

**The release tag is born in a gate.** Bazzite and bazzite-dx push the dated tag and every
alias from the build job (`bazzite-dx/.github/workflows/build.yml`); aurora pushes `:staging`,
signs it, then pushes the real tags from the same job. Here the build stops at `:staging` and a
separate job verifies the image before any tag points at it. `:stable` moves behind two
switches, where the family's moves on every run.

**Fewer actions, more bash.** `nick-fields/retry`, `softprops/action-gh-release`, `setup-oras`
and renovate are replaced by scripts of ours with `--self-test`s ([`gotchas.md`](gotchas.md)).
Bazzite's version step swallows its tag probe with `|| true`; ours aborts on a probe that fails
or returns nothing. bazzite-dx reads the base's version label; `watch-upstream.sh` compares
base digests, which also move on a retag. The family runs `ublue-os/remove-unwanted-software`
to free disk, which fails on this runner ([`gotchas.md`](gotchas.md)); no space-freeing action
runs here.

Files: `.github/workflows/` and `.github/scripts/`, one owner per script
([`architecture.md`](architecture.md)).

## The site

Seven pages for a reader who installs the image: the home, the images and their tags, the
install guide in both cases, what changes over Bazzite in plain words, the verification of
signature, attestation and SBOM, the recipes, and the questions a first rebase raises. Every
command on a page is one this documentation already runs. Each page is written as well-formed
XML, so Python's expat can prove its markup, and shares `style.css` and the same `<nav>` block.
System fonts, a light and a dark palette through `prefers-color-scheme`, no script, no asset
fetched from outside the site, no build step.

bazzite keeps its site in a separate repository, and aurora and bazzite-dx have no page, so
this is the only page in the family with a checker. `check-site.sh` runs in the lint job and
again before the upload. It refuses a symbolic or hard link in `site/`, which the Pages
artifact may not contain. On every page it refuses markup that is not well formed, any mention
of `:testing` or `:latest`, a local reference that is not a file of the directory, an asset
fetched from outside the site, a plain http link, and anything other than exactly one `<nav>`
naming every page. The home and images pages must name each of the three images as a whole
name, the home and verify pages the public key, and every https link must answer. A link into
this repository must resolve to a file of the checkout, so the page and the file ship in the
same push ([`gotchas.md`](gotchas.md)).

The publishing workflow is GitHub's `starter-workflows/pages/static.yml`, pinned, in the
`github-pages` environment, with the concurrency group `bazzite-mx-pages` and
`cancel-in-progress: false`, following the starter's comment that a production deployment is
never cancelled. The trigger is a push to `main` that touches `site/`, the check or the
workflow, or a dispatch; there is no schedule, the site having no reason to change on its own.

Files: `site/*.html`, `site/style.css`, `.github/workflows/deploy-pages.yml`,
`.github/scripts/check-site.sh`.
