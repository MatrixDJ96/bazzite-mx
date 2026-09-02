# Divergences from Bazzite

What this image changes over its base, one entry per feature, with the admission criteria of
decision 1.3 it satisfies: (1) upstream does not cover it, (2) it needs the image layer, (3) a
host of the fleet uses it, (4) it ships a smoke test and cites its source. Facts carry the
date they were measured.

## Signing trust for our own images (`11-image-signing.sh`)

Criteria 1, 2, 3, 4. Bazzite verifies `ghcr.io/ublue-os/*` against its key
(`/etc/containers/policy.json` read on the base, 2026-09-02) and says nothing about
downstream images; a host that follows `ghcr.io/matrixdj96/*` with
`ostree-image-signed:docker://` needs the scope, the key and the sigstore attachment stanza in
the image it boots. Sources: containers-policy.json(5), containers-registries.d(5) (read
2026-09-02).

## Hook framework: `ublue-setup-services` (`20-setup-services.sh`)

Criteria 1, 2, 4. The base ships no `system-setup.hooks.d` dispatcher (probed on
`ghcr.io/ublue-os/bazzite@sha256:9556db65…`, 2026-09-02: package absent, unit `not-found`).
Package 0.1.8 from COPR `ublue-os/packages`, the way bazzite-dx installs it
(`build_files/20-install-apps.sh:87-88`, `40-services.sh:6-7`). Only the system unit is
enabled here; `ublue-user-setup.service` is enabled `--global` by the first user hook (VS Code
extensions).

## Docker CE (`21-container-runtime.sh`)

Criteria 1, 2, 3, 4; decision 1.5f. Bazzite ships podman only; the developer hosts run Docker
(devcontainers, compose). Pattern bazzite-dx `build_files/20-install-apps.sh:99-116`, rewritten:

- Packages: `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`,
  the list of https://docs.docker.com/engine/install/fedora/ (read 2026-09-02). Not
  `docker-model-plugin` (bazzite-dx leaves it out; nothing on the fleet uses it).
- Repository: `[docker-ce-stable]` vendored with `enabled=0` and `gpgkey=file://`
  (bazzite-dx fetches `docker-ce.repo` at build and relies on `setopt enabled=0`, a no-op on
  repositories added from a file, v1 gotcha #2). Key "Docker Release (CE rpm)" from
  https://download.docker.com/linux/fedora/gpg, fingerprint
  `060A 61C5 1B55 8A7F 742B 77AA C52F EB6B 621E 9F35` (measured 2026-09-02).
- `docker.socket` enabled, `docker.service` left to socket activation (`Requires=docker.socket`
  in the unit, 29.7.2). `podman.socket` enabled as well (base: disabled).
- No sysctl for forwarding: "Docker needs IP Forwarding enabled on the host. So, it enables the
  sysctl settings net.ipv4.ip_forward and net.ipv6.conf.all.forwarding if they are not already
  enabled when it starts" (https://docs.docker.com/engine/network/packet-filtering-firewalls/,
  read 2026-09-02).
- `iptable_nat` in `modules-load.d` for docker-in-docker (devcontainers/features#1235,
  ublue-os/bluefin#2365).
- The `docker` group: the `%post` of docker-ce and docker-ce-cli runs `groupadd --system
  docker` at build (`rpm -qp --scripts`, 29.7.2); `95-clean-stage.sh` moves it to
  `/usr/lib/group`, `docker.socket` (`SocketGroup=docker`) resolves it through NSS `altfiles`,
  and the boot hook `10-bazzite-mx-groups.sh` copies the line into `/etc/group` and adds every
  wheel member. Positive control for the relocation: with the `docker` line put back into
  `/etc/group`, `bootc container lint --fatal-warnings` fails on its `sysusers` check (measured
  2026-09-02 on the pre-flight image, exit 1). "The docker group grants root-level privileges to the user"
  (https://docs.docker.com/engine/install/linux-postinstall/): granting it to wheel is the
  bazzite-dx choice (`20-dx.sh`), kept because the fleet's wheel users are the machines'
  administrators. Revoke per user with `gpasswd -d <user> docker`.
- Residual: the `%post` loads an SELinux module (`docker-af-alg-deny.cil`) only when
  `selinuxenabled`, which is false in the build container, so hosts run without that AF_ALG
  denial (upstream's own `|| warning` path).
- Also from Fedora, in the same script: `podman-compose`, `podman-machine`, `podman-tui`
  (bazzite-dx `20-install-apps.sh:15-16`) and `bcvk` (bootc images as VMs; aurora's
  replacement for the archived podman-bootc, commit 7e31b429).

## Virtualization and quickemu (`22-virtualization.sh`)

Criteria 1, 2, 3, 4; decision 1.5f, quickemu added by the owner (2026-09-02). Bazzite ships
`edk2-ovmf` and the `kvmfr` module (`install-kernel-akmods`) but no libvirt, QEMU or
virt-manager: its `setup-virtualization` recipe installs the virt-manager Flatpak and enables
the monolithic `libvirtd` per host. Here (pattern bazzite-dx `20-install-apps.sh:29-39`, aurora
`dx/00-dx.sh:40-66,106,127`, rewritten):

- Packages from Fedora, explicit list, weak dependencies off: `libvirt libvirt-daemon-kvm
  libvirt-nss qemu-kvm qemu-img qemu-char-spice qemu-device-display-virtio-{gpu,vga}
  qemu-device-usb-redirect virt-manager virt-viewer virt-install swtpm swtpm-tools
  guestfs-tools waypipe quickemu`. `libvirt-nss` ships the `libvirt_guest` NSS module; the
  image does not add it to `nsswitch.conf` (a host's choice).
- Daemons: modular, from Fedora 44's preset (`90-default.preset` enables `virtqemud.service`
  and the `virt*d` sockets; "New distributions are likely to use the modular mode",
  https://libvirt.org/daemons.html, read 2026-09-02). `libvirtd.service` stays disabled and
  the build asserts it; v1 enabled both.
- `ublue-os-libvirt-workarounds` 1.1 (COPR `ublue-os/packages`): `restorecon` of
  `/var/{lib,log}/libvirt` at boot, tmpfiles for `/var/log/libvirt`, sysusers for `libvirt`.
- `/var` directories: the packages ship `/var/lib/libvirt/*`, `/var/lib/swtpm-localca` (tss),
  `/var/log/swtpm/...`; the image ships no `/var` content, so
  `usr/lib/tmpfiles.d/bazzite-mx-virt.conf` lists them with the packaged owner and mode
  (`rpm -qlv`, 2026-09-02). On the v1 host `rpm-ostree-autovar.conf` carries no libvirt line
  (measured 2026-09-02): the autovar mechanism does not recover directories a build removed.
- KVM: `usr/lib/modprobe.d/bazzite-mx-kvm.conf` sets `ignore_msrs=1 report_ignored_msrs=0`,
  the values Bazzite's recipe adds as kernel arguments; `kvm` is a module in the ogc kernel
  (`CONFIG_KVM=m`), so the option applies without a karg.
- quickemu 4.9.9 (Fedora; https://github.com/quickemu-project/quickemu/wiki/01-Installation:
  "sudo dnf install quickemu"). It requires the `qemu` meta package, which pulls `qemu-user`
  and the system emulators of every architecture: +131 MiB of packages (506 vs 375 MiB for
  the list above, measured 2026-09-02 in `fedora:44`). `qemu-user-binfmt` and
  `qemu-user-static` are not pulled (asserted in the build; decision 1.5a). It also requires
  `mesa-demos`, which the base's `exclude=mesa-*` on the Fedora repositories
  (`/etc/dnf/repos.override.d/99-config_manager.repo`, Mesa comes from Terra) filters out: the
  build lifts that exclude for the one package and asserts that no other `mesa-*` package
  changed (measured 2026-09-02: one package, Terra's Mesa untouched).
- Recipe `setup-virtualization` (file `84-bazzite-virt.just`, replacing Bazzite's): `status`
  (daemon, `/dev/kvm`, group, `virsh`, kvm options, kvmfr, quickemu) and `kvmfr` (runs
  bazzite-dx's `bazzite-dx-kvmfr-setup`, commit a0f3842, plus the two bold codes it prints but
  never set). Not carried over
  from bazzite-dx's version: VFIO on/off, SPICE USB hot-plug udev rule, the `setfacl` on
  `$HOME`, the VFIO-Tools libvirt hook download; each returns as its own recipe if a host
  needs it.
- The `libvirt` group is granted to wheel members by the boot hook, like `docker`: Fedora's
  `50-libvirt.rules` gives that group `org.libvirt.unix.manage` without a password.

## Visual Studio Code (`30-ide.sh`)

Criteria 1, 2, 3, 4; decision 1.5a (RPM from Microsoft's repository, extensions hook kept).
Pattern bazzite-dx `20-install-apps.sh:94-97` (Microsoft's `config.repo` fetched at build,
`gpgcheck=0`, `setopt enabled=0`), rewritten: `vscode.repo` vendored with the stanza
https://code.visualstudio.com/docs/setup/linux gives (`[code]`, `gpgcheck=1`), the key
"Microsoft (Release signing)" shipped in the image, fingerprint `BC52 8686 B50D 79E3 39D3
721C EB3E 94AD BE12 29CF` (measured 2026-09-02 on
https://packages.microsoft.com/keys/microsoft.asc; the packages are signed with it, `rpm -qp`
on code 1.135.0). Skel `settings.json` sets `update.mode` to `none`
(https://code.visualstudio.com/docs/supporting/faq: "Configure the Update: Mode setting from
default to none"): the RPM follows the image. The user hook
`11-bazzite-mx-vscode-extensions.sh` seeds the settings for accounts that predate the image and
installs `ms-azuretools.vscode-containers`, `ms-vscode-remote.remote-containers`,
`ms-vscode-remote.remote-ssh` (bazzite-dx's set) when `~/.vscode/extensions/extensions.json`
lacks them, at every login, without a version stamp.

## Git tools (`31-git-tools.sh`)

Criteria 1, 2, 3, 4; decision 1.5b (GitKraken as RPM in the image, the owner's choice over
the Flatpak) and the "Regola RPM" (latest release, no pin). GitKraken publishes one fixed URL,
https://release.gitkraken.com/linux/gitkraken-amd64.rpm: HEAD answers 404, GET redirects to
`release.gitkraken.dev/gkd/production/normal/linux/x64/<version>/<token>/gitkraken-amd64.rpm`
(12.4.0, 216 MB, measured 2026-09-02). The RPM carries no OpenPGP signature (`rpm -Kv` lists digests only; `%{SIGPGP}` and
`%{RSAHEADER}` empty, re-measured 2026-09-02) and no scriptlets; the build checks its payload digests (`rpm -K --nosignature`) and installs
it with `--no-gpgchecks` for that file only. Its one dependency, `libXScrnSaver`, is in the
base. `git-credential-libsecret` from Fedora (aurora `base/01-packages.sh:64`).

## Command-line tools (`32-cli-rpms.sh`)

Criteria 1, 3, 4; decision 1.5b. `gh glab ShellCheck shfmt` and the v1 system-administration
list `android-tools bcc bcc-tools bpftop bpftrace ccache flatpak-builder iotop-c nicstat
numactl ripgrep sysprof trace-cmd`, all Fedora 44 (`repoquery` 2026-09-02; none in the base).
Fedora's shfmt is 3.7.0, the release CI and the edit hook format with. v1 pinned gh, glab,
shellcheck and shfmt as binaries by version and sha256; the Fedora packages replace that.

## mise (`33-mise.sh`)

Criteria 1, 2, 3, 4; decision 1.5c (bazzite-63 0b36480) with the RPM form the owner confirmed
at the design checkpoint. bazzite-63 ships only `profile.d` and the skel config and installs
mise per user through Homebrew; here `mise` comes from the COPR its documentation names
(https://mise.jdx.dev/installing-mise.html: `dnf copr enable jdxcode/mise`), vendored as
`mise.repo` with `enabled=0` and the project key shipped in the image (fingerprint `9504 792D
1F9C CA15 14FD 1DEC 8497 A816 C83E 991C`, valid to 2030-07-19, measured 2026-09-02).
`/etc/profile.d/mise.sh` runs `mise activate bash` in interactive bash (Fedora's `/etc/bashrc`
sources `profile.d` for non-login shells too); the skel `~/.config/mise/config.toml` names
node lts, python 3.14, java temurin-21, dotnet 10, installed per user with `mise install`
(a `setup-dev` recipe arrives with the justfile feature). Other shells activate mise
themselves; the package ships their completions.

## Desktop applications (`40-desktop-apps.sh`, `80-fix-opt.sh`)

Criteria 1, 2, 3, 4; decision 1.5b (Firefox as Fedora's RPM, 1Password installed in the
build), gparted and teams-for-linux from the design checkpoint (2026-09-02).

- **Firefox**: Bazzite removes `firefox` and `firefox-langpacks` ("we use the flatpak",
  `build_files/global-remove:8`). The RPM (`firefox 154.0-5.fc44`, `firefox-langpacks`,
  Fedora updates, 2026-09-02) is back by the owner's decision; v1's reason, kept, is the
  browser-host integration of 1Password (native messaging with
  `/opt/1Password/1Password-BrowserSupport`, a host binary a sandboxed Firefox does not
  reach out of the box). The Flatpak is denied through the mechanism Bazzite already runs at every
  boot: `bazzite-flatpak-manager` (unit `WantedBy=multi-user.target`) passes
  `/usr/share/ublue-os/flatpak-blocklist` to `flatpak remote-modify --filter` on Flathub
  (`usr/libexec/bazzite-flatpak-manager:38-39`), and "if a ref matches a deny rule it is
  disallowed unless it specifically matches an allow rule" (flatpak-remote-add(1),
  `--filter`, flatpak 1.18.1). The build appends `deny org.mozilla.firefox/*` after the
  base's lines (Steam, Lutris) on a fresh inode and asserts the count. The list
  `/usr/share/ublue-os/bazzite/flatpak/install` is not edited: nothing in the image reads it
  (grep on the bazzite checkout 54256f95, 2026-09-02; v1 measured the same on its image). A
  host that already has the Flatpak keeps it installed: the migration recipe prints the
  profile copy and leaves the uninstall to the user (design 2.0 § 7, item 5.1 of the
  refutation).
- **gparted** `1.7.0-3.fc44`, Fedora; Bazzite ships `gnome-disk-utility` in its place
  (`configure-kde`) and gparted only on the live ISO.
- **1Password** from the vendor's repository, the stanza of
  https://support.1password.com/install-linux/ (read 2026-09-02) vendored with `enabled=0`
  and the key "Code signing for 1Password <codesign@1password.com>" from
  https://downloads.1password.com/linux/keys/1password.asc, fingerprint
  `3FEF 9748 469A DBE1 5DA7 CA80 AC2D 6274 2012 EA22` (the page prints it; measured with
  `gpg --show-keys`, valid to 2032-05-16). `repo_gpgcheck=1` stays: the repository publishes
  `repodata/repomd.xml.asc` (HTTP 200, 2026-09-02); the package's own `.repo` comments it
  out for a dnf4-era bug (bugzilla 1768206). 8.12.34 on 2026-09-02; the RPM carries a
  header signature by the same key (`rpm -Kv`: "Header OpenPGP V4 RSA/SHA512 signature, key
  ID ac2d62742012ea22"; `%{SIGPGP}` is empty, the signature lives in `%{RSAHEADER}`), which
  `gpgcheck=1` verifies against the vendored key. Installing at build instead of layering on the host is what makes
  `bootc status` compatible (decision 1.7). What the `%post` does and how each effect is
  handled (`rpm -qp --scripts`, 2026-09-02):
  - it writes `/etc/yum.repos.d/1password.repo` with `enabled=1` and an https `gpgkey`
    (`installRpmChannel`): the build reinstalls the vendored copy and asserts it, and
    `90-validate-repos.sh` would refuse the rewritten file anyway (its self-test covers
    "vendored repo enabled");
  - it renders `/usr/share/polkit-1/actions/com.1password.1Password.policy` from a template,
    filling `org.freedesktop.policykit.owner` on `authorizeCLI` and `authorizeSshAgent` with
    the first ten UID ≥ 1000 users of `/etc/passwd` (`installFiles`; the `unlock` action
    carries no owner annotation). A build has no such user, so the annotation ships empty.
    That is not a regression: polkit lets a process check the authorization of another
    process of the **same** user without being an owner, the annotation only widens who may
    query for *other* users' processes (polkit(8) § "org.freedesktop.policykit.owner": "If
    this annotation is not specified, then only root can query whether a client running as a
    different user is authorized"; `polkitbackendinteractiveauthority.c:1104-1123`, read
    2026-09-02), and the 1Password app, CLI and SSH agent all run as the same user. The host
    that layers 8.12.34 today already runs with the annotation empty (rpm-ostree renders the
    `%post` in a build root without human users: policy file read on ldesktop-zrombi,
    2026-09-02) and the owner reports system-authentication unlock working there
    (refutation 2.6). The design's polkit rule (2.0 § 3, refutation
    2.6) is therefore not added: a `polkit.addRule` returning `YES` for `unlock` would
    remove the password prompt, and no rule can set an owner annotation. The vendor ships
    `/opt/1Password/install_biometrics_policy.sh -f` to re-render the file with owners on a
    host; not needed on the hub (owner's report), the fallback should a host show otherwise;
  - it creates the groups `onepassword` and `onepassword-mcp` when `getent` does not find
    them, and sets the group and setgid bit on `1Password-BrowserSupport` and
    `1password-mcp` ("hardens it against environmental tampering", `SO_PEERCRED` for the
    MCP server). Its `groupadd` has no `--system`, so in a build the groups take gid 1000
    and 1001, the gids of a host's first human users (measured on the first pre-flight,
    2026-09-02; the host that layers the package shows 1001 and 1003), and the setgid
    binaries would run with a user's primary group. A system gid is not an answer either:
    the desktop app rejects a BrowserSupport whose group id is below 1000 (the pilot's
    first v2 boot, 2026-09-03, gid 951: [`gotchas.md`](gotchas.md); NixOS `ids.nix:734`
    "1Password requires that its GID be larger than 1000"; the Gentoo overlay's
    `acct-group/onepassword` uses 1010 "from previous issues"). The build creates both
    groups first with the fixed gids 31001 and 31002 (NixOS's reservations) and asserts
    them on the group file and on the two binaries; `95-clean-stage.sh` relocates them to
    `/usr/lib/group`; no user needs membership, so the boot hook's group list is
    unchanged;
  - it sets `chrome-sandbox` to 4755 (electron/electron#17972) and symlinks
    `/usr/bin/1password` and `/usr/bin/1password-mcp` into `/opt/1Password`;
  - it installs `/etc/1password/custom_allowed_browsers` (an `/etc` file, merged on the
    host as usual).
- **`/opt` payload** (`80-fix-opt.sh`): the image's `/opt` is a symlink to `var/opt`
  (base tree), `/var/opt` is created on a host by rpm-ostree's tmpfiles line
  (`rpm-ostree-0-integration-opt-usrlocal.conf`) but does not exist in a build, so an RPM
  unpacking under `/opt` dies in cpio (bazzite-63 gotcha #28, measured 2026-07-09), and
  the build wipes `/var` anyway. `40-desktop-apps.sh` creates `/var/opt` before the install
  and `80-fix-opt.sh` moves every `/var/opt/<name>` to `/usr/lib/opt/<name>` (the base
  ships that directory, empty) and writes `usr/lib/tmpfiles.d/bazzite-mx-opt.conf` with one
  `L+ /var/opt/<name> - - - - /usr/lib/opt/<name>` line per directory, so the `/opt/...`
  paths the application and its `.desktop` file carry resolve on the host. Pattern
  bazzite-dx `build_files/50-fix-opt.sh` (AmyOS `fix-opt.sh` before it), rewritten: the
  checks (directory, not a symlink, no namesake under `/usr/lib/opt`) run before the first
  move, the tmpfiles file is written whole, and `--self-test` refuses the three bad layouts.
  bootc's guidance for `/opt` content is the same "move and link" (docs `filesystem.md` §
  `/opt`, `building/guidance.md`, read 2026-09-02). The smoke test applies the file with
  `systemd-tmpfiles --root=<fixture> --create` and reads the link back.
- **teams-for-linux**: not in the image. A preinstall would put Teams on hosts that do not
  use it (criterion 3) and `flatpak preinstall` synchronises, so removing the entry later
  would uninstall the app (flatpak-preinstall(1), 1.18.1). The Flathub id
  `com.github.IsmaelMartinez.teams_for_linux` and the `flatpak install` command go in
  `docs/migration.md` with the justfile feature.

## Sunshine (`41-sunshine.sh`)

Criteria 1, 2, 3, 4; decision 1.5e (RPM from the COPR `lizardbyte/stable`, an enabling
recipe, the base's virtual-monitor helpers reused). Bazzite dropped its Sunshine RPM
(commit 079fa8ad, 2026-03-26) and its `setup-sunshine` installs the Flatpak per host, with a
Homebrew beta path for Deck images. The RPM is in the image because the Flatpak cannot do
what the fleet uses it for: "Flatpak does not support KMS capture"
(`docs/getting_started.md:235`) and "KMS screencasting requires elevated privileges which
are not allowed for Flatpak or AppImage packages" (`docs/troubleshooting.md:237`,
LizardByte/Sunshine master, read 2026-09-02); the same page notes KMS "will soon be phased
out in favour of XDG Portal Capture", which the RPM supports too.

- Package `Sunshine` (capital S) `2026.516.143833-1.fc44` from the COPR the Sunshine docs
  name (`docs/getting_started.md:213`: `sudo dnf copr enable lizardbyte/stable`), vendored
  as `sunshine.repo` with `enabled=0`, the COPR key shipped (fingerprint `1827 C306 E994
  4D99 DF4C ACF1 43B8 4301 E4F6 8234`, valid to 2029-10-04, measured 2026-09-02) and the
  COPR file's `priority=1` dropped (it would let the repository override Fedora's packages
  on a host that enabled it). v1 used the community COPR `pvermeer/sunshine` because the
  official one lacked the capability and Fedora builds; both objections are gone: the
  official RPM ships `/usr/bin/sunshine` with `cap_sys_admin,cap_sys_nice=p` (`rpm --qf
  '%{FILECAPS}'`, 2026-09-02) and a Fedora 44 build. The capability is what KMS capture
  needs; it also means a compromised Sunshine process holds `CAP_SYS_ADMIN` for the user
  running it, accepted as in v1 because the unit is opt-in and the hosts are single-user.
- What the RPM ships and the build only checks: the user unit
  `app-dev.lizardbyte.app.Sunshine.service` (`Alias=sunshine.service`,
  `WantedBy=graphical-session.target`), `60-sunshine.rules` (`/dev/uinput` and `/dev/uhid`
  to group `input` with `uaccess`), `60-sunshine.conf` (modules-load `uhid`). Its `%post`
  runs `modprobe uhid` and, only where `rpm-ostree` is absent, `udevadm` reloads; in the
  build both are no-ops and the files apply at boot.
- The unit is disabled for every user (`systemctl --global disable`, aurora
  `17-cleanup.sh:32`; asserted after the install rather than assumed from the presets) and
  enabled per user by the recipe: streaming is opt-in.
- Bazzite's announcement `sunshine-brew.msg.json` ("Sunshine will soon be removed from the
  base Bazzite image, and you will need to reinstall it in Bazzite Portal") fires for any
  user whose journal mentions sunshine and whose user units include the RPM's: removed, as
  v1 did.
- Recipe `setup-sunshine` (file `82-bazzite-sunshine.just`, replacing Bazzite's 336-line
  recipe): `status`, `enable`/`disable` (`systemctl --user`), `portal`, `virtual-monitor`
  (the "Virtual Monitor" app of Bazzite's recipe rewritten for the RPM: the base's
  `sunshine-start-vmon`/`sunshine-stop-vmon` called directly, `~/.config/sunshine/apps.json`
  seeded from the package's `apps.json`, the `ExecStopPost` drop-in). Not carried over:
  install/update/uninstall paths (the RPM follows the image), the Deck and Homebrew
  branches (no Deck image in the fleet), the "Fix Error 503" switch that writes
  `KWIN_WAYLAND_NO_PERMISSION_CHECKS=1` into the user's environment (a KWin permission
  bypass; returns as its own step if a host needs it).
