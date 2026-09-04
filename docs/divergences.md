# Divergences from Bazzite

What this image changes over its base, one entry per feature, with the admission criteria of
decision 1.3 it satisfies: (1) upstream does not cover it, (2) it needs the image layer, (3) a
host of the fleet uses it, (4) it ships a smoke test and cites its source. Facts carry the
date they were measured.

## Three flavours, one recipe (`Containerfile`, `resolve-base.sh`)

Bazzite publishes one image per graphics stack: `bazzite` (AMD, Intel), `bazzite-nvidia-open`
(the open kernel modules, Turing and newer) and `bazzite-nvidia` (the closed driver, for the
GPUs the open modules do not cover). The image follows all three: `bazzite-mx`,
`bazzite-mx-nvidia-open`, `bazzite-mx-nvidia`, the base being the only difference
(`Containerfile` takes `BASE_IMAGE`; `resolve-base.sh` maps flavour to image name and pins
the base to its digest). Criteria (1) and (3): upstream covers each stack, but a host that
needs the image's other divergences on one of them can get them only from an image built on
that base; the fleet has NVIDIA hosts on the open modules and the closed flavour is kept
buildable and published for the day a GPU needs it. What differs between the bases and
matters here:

- **The closed base carries its own kernel.** `bazzite-nvidia:stable` 44.20260902 ships
  6.18.48-ogc1.1 where the other two ship 7.2.1-ogc4.1 (MEASURED 2026-09-04 08:45Z,
  `skopeo inspect`, label `ostree.linux`), with `kernel-devel-matched`, gcc, make and
  binutils for it (MEASURED the same day, `podman run … rpm -q`). The kmod-builder stage
  compiles the out-of-tree modules against whatever kernel its base carries, so each flavour
  gets modules for its own kernel and the release notes list one kernel per image.
- **Every enumeration is literal and complete.** `PACKAGES` (`lib.sh`) names the three
  packages and every count derives from it (the env files the gate and the changelog
  expect, the promotion's report); the matrix (`reusable-build.yml`), the retention list
  (`clean.yml`), the recovery signer's `case` (`sign-image.yml`) and the watcher's
  `FLAVOURS` list them one by one; the name regex is `^bazzite-mx(-nvidia(-open)?)?$` in
  every script and test that reads an image name.
- **A package that was never published has no tag taken.** `release-tag.sh` probes every
  package for taken tags; GHCR answers `name unknown` to a logged-in probe of a package that
  does not exist yet and 403 to an anonymous one (MEASURED 2026-09-04, skopeo 1.22.2), so the
  version job of `release.yml` logs in first and the probe takes that answer as "no tags",
  while any other registry error still fails it closed. The watcher classifies the same
  answer as "absent" (`absent_error`), next to a missing tag's `manifest unknown`.

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
(`ujust setup-dev install` seeds the config for an existing account and runs it). Other shells activate mise
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
  `com.github.IsmaelMartinez.teams_for_linux` and the `flatpak install` command are in
  `docs/migration.md` and in what `ujust migrate apply` prints at its end.

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

## KDE defaults (`45-kde-defaults.sh`)

Criteria 1, 3, 4 (criterion 2 by form: per-user defaults reach existing accounts only from
the image); decision 1.5c, from bazzite-63 ee64b63, b0c5576 and 82293fc, rewritten. Not
carried over from bazzite-63 (decision 1.5c): the Segoe fonts, the Konsole pwsh profile.

- **Form**: Plasma update scripts under
  `/usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/`, the mechanism Plasma
  itself and Bazzite (`bazzite-pins.js`) use for one-shot per-user defaults: "when
  plasmashell is started, it will check for scripts with a .js suffix in the current shell
  package under the updates directory ... executed serially in the alphabetical order of the
  file names", recorded in `~/.config/plasmashellrc` `[Updates] performed` (KDE developer
  docs, Plasma scripting; plasma-workspace `shell/scripting/scriptengine.cpp:260-301`, read
  2026-09-02). They run for new accounts after the default layout and for existing accounts
  at their next plasmashell start (`shellcorona.cpp`, `processUpdateScripts`). bazzite-63
  ran the same JavaScript from `/etc/xdg/autostart` entries with a per-user stamp file and a
  60-second wait for plasmashell on the session bus; the update-script form needs neither.
  A JavaScript error is only a `qCWarning` in the journal and the script is still marked
  performed (`shellcorona.cpp:1153-1155`; refutation 2.9), so the files are checked with
  `node --check` before a commit and by the CI lint job (no JavaScript engine in the image),
  and their effect is proven on the hub with an existing account in phase 4.
- **Clock seconds** (`bazzite-mx-clock-seconds.js`): every digital clock on a panel or
  desktop gets `showSeconds=2` (always) when it still has the upstream default (1, tooltip
  only); a clock the user set to "never" (0) is left alone. Values as in the base's own
  `digitalclock_migrate_showseconds_setting.js`.
- **A panel per screen** (`bazzite-mx-panels.js`): for every screen from 1 to
  `screenCount-1` without any panel, a bottom panel copying the primary panel's height,
  floating, hiding, alignment and length mode, and its widgets except
  `org.kde.plasma.systemtray` (a second tray applet spawns a duplicate tray containment),
  with the task manager set to `showOnlyCurrentScreen` and the primary's pinned launchers;
  falls back to the default panel's widget list when no primary panel is found. A screen
  that already carries a panel is skipped, so an existing multi-screen layout is never
  changed (refutation 2.9). `Panel.screen` is writable in Plasma 6 (`shell/scripting/panel.h:30`).
  A first login with one screen adds nothing and the script is still marked performed:
  `ujust setup-panels` evaluates the same file through `org.kde.PlasmaShell.evaluateScript`,
  which returns the script's `print` output (`shellcorona.cpp`, `evaluateScript`).
- **Ctrl+C / Ctrl+V** (skel `~/.local/share/kxmlgui5/konsole/sessionui.rc`, skel
  `~/.config/powershell/profile.ps1`): Konsole gets `edit_copy` on `Ctrl+C; Ctrl+Shift+C`;
  Konsole disables the action while nothing is selected, so Ctrl+C still interrupts the
  shell. The file's `version="1"` is below Konsole's `sessionui.rc` (`version="36"`, master
  2026-09-02), so KXmlGui merges only its `ActionProperties` into the application's layout;
  KF6 still reads `GenericDataLocation/kxmlgui5/<component>/` (`kxmlguiclient.cpp:160`).
  PowerShell is not in the image (decision 1.5c keeps the Konsole pwsh profile out); the
  profile applies to a pwsh the user installs and binds Ctrl+C to copy-selection-or-cancel
  and Ctrl+V to paste through `wl-copy`/`wl-paste` (wl-clipboard 2.2.1 is in the base,
  measured 2026-09-02; PSReadLine's own clipboard functions need xclip on Linux).

## MSI laptop: kernel modules and MControlCenter (`50-kmods.sh`, `bazzite-mx-msi-setup`, `setup-msi`)

Criteria 1, 2, 3, 4; decisions 1.5a (readopt msi-ec, acpi_ec, `setup-msi`), 1.5g (commit
pin, vermagic verified), owner's decision of 2026-09-02 (MControlCenter outside the image,
installed per host). The fleet's laptop is an MSI (llaptop-matrix, RTX 4070).

- **msi-ec** (BeardOverflow/msi-ec, main `d7fbbd88`, 2026-09-02): the ogc kernel builds
  its in-tree copy (`CONFIG_MSI_EC=m`) but that copy prints no version and lags the project;
  the out-of-tree 0.13 lands in `/usr/lib/modules/<kver>/updates/msi-ec.ko`, which depmod
  searches before `kernel/` ("For backward compatibility add 'updates' to the head of the
  search list", kmod `tools/depmod.c:913-917`; the base ships no `depmod.d`), so
  `modprobe msi-ec` resolves to it and the in-tree file stays untouched. The build asserts the
  resolution.
- **acpi_ec** (saidsay-so/acpi_ec, master `e83e5a61`, the v1.0.4 driver): a character device
  `/dev/ec` (root only) that MControlCenter uses for fan speeds and curves when
  `/sys/kernel/debug/ec/ec0/io` is absent (`src/helper/readwrite.cpp:24-26`), and it is
  absent: the ogc kernel leaves `CONFIG_ACPI_EC_DEBUGFS` unset (measured 2026-09-02), so no
  `ec_sys` exists to load.
- **Builder**: the base image itself, not the akmods carrier (design 2.3 planned the carrier):
  Bazzite installs `kernel-devel` for its kernel and versionlocks it
  (`build_files/install-kernel-akmods:30-32`), and gcc, make, binutils, elfutils-libelf-devel
  and git-core are in the base (measured 2026-09-02 on 7.2.1-ogc4.1; both modules build in
  9 s). The kernel's build system is called directly (`make -C /usr/src/kernels/<kver> M=`),
  not the modules' own `make`, which targets `/lib/modules/$(uname -r)/build` — the runner's
  kernel, not the image's (msi-ec `Makefile:17`, acpi_ec `Makefile:14`). Debug sections are
  stripped the way `make modules_install INSTALL_MOD_STRIP=1` strips (`scripts/Makefile.modinst:76-85`,
  `--strip-debug`; 561 KB → 98 KB for msi-ec), and the `.ko` ships uncompressed like the base's
  in-tree modules (`CONFIG_MODULE_COMPRESS_ALL` unset; v1 shipped `.ko.xz` with the crc32
  constraint of the in-kernel decompressor, which no longer has a reason here).
- **Unsigned**: `CONFIG_MODULE_SIG=y`, `CONFIG_MODULE_SIG_ALL=y`, no `CONFIG_MODULE_SIG_FORCE`
  (measured): the modules load with a taint when Secure Boot is off and are refused by
  lockdown when it is on; the recipe prints that reason when modprobe fails. The laptop runs
  with Secure Boot disabled (`bootctl status`, 2026-09-04, refutation 3b) and both modules
  were loaded by the image's `modules-load.d` file on its first v2 boot; MOK enrolment stays
  out of scope.
- **Not loaded by the image**: no modules-load file ships; every other host of the fleet
  never touches the modules. `ujust setup-msi enable`, gated on DMI vendor `Micro-Star`,
  writes `/etc/modules-load.d/bazzite-mx-msi.conf` and loads them now. Bazzite's own vendor
  tools load at runtime on DMI as well (`usr/libexec/hwsupport/*`), but as RPMs in the image;
  the per-host install of MControlCenter is the owner's choice against that model.
- **MControlCenter** (dmitry-s93/MControlCenter, latest release resolved at run time through
  the GitHub API, no pin — "Regola RPM"; 0.5.1 of 2025-07-18 today, tarball
  `MControlCenter-0.5.1-bin.tar.gz`, sha256 `704849b9…41b0`, measured 2026-09-02). Not on
  Flathub. Upstream's `scripts/install.sh` puts the GUI in `/usr/bin`, the helper in
  `/usr/libexec`, the D-Bus policy in `/usr/share/dbus-1/system.d`, the activation file in
  `/usr/share/dbus-1/system-services`; on a bootc host `/usr` is the image, so
  `bazzite-mx-msi-setup install` puts everything under `/usr/local` (`/var/usrlocal`) and
  `/etc/dbus-1/system.d`: dbus-broker's launcher searches
  `/usr/local/share/dbus-1/system-services` for system services
  (bus1/dbus-broker `src/launch/launcher.c:957-965`) and `/etc/dbus-1/system.d` is an
  `<includedir>` of `system.conf` (dbus 1.16.2). The helper goes to `/usr/local/bin`, not
  `libexec`: SELinux labels `/usr/local/bin` `bin_t` like `/usr/libexec`, while
  `/usr/local/libexec` has no file_contexts entry and falls to `usr_t` (`matchpathcon` on the
  host of record, 2026-09-02); the activation file's `Exec=` is rewritten to that path and
  asserted. Privilege model, upstream's: D-Bus activation runs the helper as root
  (`User=root`), the policy lets every local user send to it, no polkit (`src/helper/
  mcontrolcenter.helper.service`, `mcontrolcenter-helper.conf`): any local user of the laptop
  can drive the embedded controller through it, accepted as in v1 on a single-user machine.
  After the install the script reloads the bus (`org.freedesktop.DBus.ReloadConfig`) and
  asserts the name is activatable. The install and remove paths run in the smoke test on a
  fixture root with a synthetic tarball of the release layout (positive, and two known-bad
  tarballs refused before anything lands); the real tarball was run through the same code
  on the host of record before the commit; the D-Bus activation of a root helper from
  `/usr/local/bin` is proven on the laptop (2026-09-04: `ujust setup-msi enable` installed
  0.5.1, `busctl --system introspect mcontrolcenter.helper /` started the helper as root,
  pid read back, `setup-msi status` reported the EC firmware).
- v1 layered `mcontrolcenter` from the COPR `teackot/msi` with rpm-ostree, which is what makes
  `bootc status` report `incompatible` (decision 1.7); nothing is layered here.
- **Not in the initramfs, by design**: the two modules live under
  `/usr/lib/modules/<kver>/updates/` and are loaded by `modules-load.d` after the switch-root;
  `lsinitrd` on the image's `initramfs.img` lists neither (2026-09-04, tree `8f70f30`). A module
  that dracut does pull in (`amdgpu`, `ntfs3`, the NVIDIA typec/hid ones are inside) cannot be
  replaced by writing the `.ko` and running `depmod` alone: the kernel loads the copy in the
  initramfs and the change is silently inert until `dracut` regenerates the image in the same
  layer (measured on the hub by the FRL round, 2026-09-04: a patched `amdgpu.ko` on disk, the
  stock one hashed inside the booted initramfs). v2 replaces no in-tree module; the day it
  does, the build regenerates the initramfs in the same layer and fails unless the module
  unpacked from it hashes like the installed one (the guard the FRL round added).
  Second trap from the same round (2026-09-04, hub): `dracut --no-hostonly` run inside the
  container does not detect an ostree root and drops `ostree-prepare-root` from the image it
  writes (0 hits against 3 in the base's initramfs), so the deployment stops in the initramfs
  with no error at build time; a regeneration in-image forces the ostree dracut module and
  checks the unpacked initramfs for it.
  Third trap, same round: `rd.driver.blacklist=<module>` is not initramfs-scoped in
  practice — dracut writes it to `/run/modprobe.d/initramfsblacklist.conf`, `/run` survives
  the switch-root, and udev never autoloads the module in the real root either (the hub ran
  its desktop without `amdgpu` on that boot); only an explicit `modprobe` ignores a
  `blacklist` line.

## NTFSPLUS as a per-host opt-in (`55-ntfsplus.sh`, `bazzite-mx-ntfsplus-setup`, `setup-ntfsplus`)

Criteria 1, 2, 3, 4; decision 1.5a (the in-kernel `ntfs3` is the fleet's baseline; NTFSPLUS
returns "in a separate round after a green baseline", which is this one); the owner's rule
that no host changes driver without its own decision.

- **What it is**: NTFSPLUS is the from-scratch read/write NTFS driver on iomap and folios
  that Linux 7.1 carries as `fs/ntfs` (Namjae Jeon, the author of exFAT and ksmbd; `ntfs3`
  and it coexist: `fs/ntfs3/Kconfig` `depends on !NTFS_FS || m`). The ogc kernel builds it
  off (`# CONFIG_NTFS_FS is not set` in the base's kernel config, measured 2026-09-04 on
  7.2.1-ogc4.1 and on the closed flavour's 6.18.48-ogc1.1), so the image builds the author's
  standalone packaging of the same code (`namjaejeon/linux-ntfs`, pinned to a merge commit of
  `main`: `ntfs-next` is force-pushed) in the kmod-builder stage. The module is `ntfs.ko`
  and registers the filesystem type `ntfs` (`MODULE_ALIAS_FS("ntfs")`): "ntfsplus" is the
  project's name, never the module's nor the mount type's.
- **Why an opt-in, and how it is one**: `system_files/usr/lib/modprobe.d/bazzite-mx-ntfsplus.conf`
  ships `blacklist ntfs`, which stops the kernel from loading the driver by alias — the
  first `mount -t ntfs` — while an explicit `modprobe ntfs` still works. kmod reads
  `/etc/modprobe.d` before `/usr/lib/modprobe.d` and skips a later file of the same name, so
  a `/etc/modprobe.d/bazzite-mx-ntfsplus.conf` holding only comments masks the blacklist
  (measured 2026-09-04 with kmod 34.2: `modprobe -n -v fs-ntfs3` printed nothing under a
  test blacklist, `modprobe -c` lost the line once a twin with the helper's three comment
  lines existed in `/etc`). `enable` proves the mask on the host before loading anything:
  no `blacklist ntfs` in `modprobe -c` and `fs-ntfs` resolving to an `insmod` line. That file is
  the opt-in; `ujust setup-ntfsplus enable` writes it, `disable` removes it, `verify-host`
  and `migrate` read it. No `modules-load.d` entry is needed: the kernel autoloads a
  filesystem module by alias at the first mount of its type, the early fstab mounts included.
- **The mount helpers**: `mount(8)` hands any type with a `/sbin/mount.<type>` helper to it
  before the kernel sees the type, and `ntfs-3g` installs `mount.ntfs` and `mount.ntfs-fuse`
  in `/usr/bin` and `/usr/sbin` as links to `mount.ntfs-3g` (six links, measured on the base
  2026-09-04). With them in place `mount -t ntfs` from fstab, a `.mount` unit or `mount -t
  auto` lands on FUSE (`fuseblk`), and `mount -i`, the only way past the helper, has no fstab
  equivalent. `55-ntfsplus.sh` removes those four links; `mount.ntfs-3g`, `ntfs-3g`,
  `ntfsprogs` (`mkntfs`, `ntfsfix`) stay, so `mount -t ntfs-3g` remains the explicit FUSE
  route. Consequence on a host that did not opt in: an explicit `mount -t ntfs` fails with
  "unknown filesystem type" instead of landing on FUSE silently; `ntfs3` and `ntfs-3g` are
  the types to name. udisks2 2.11.2 prefers `ntfs` then `ntfs3` (`ntfs_drivers=ntfs,ntfs3`
  compiled in, no `mount_options.conf` in the base): its behaviour with the helper gone is
  measured on the pilot host and recorded here.
- **The recipe**: `ujust setup-ntfsplus enable` (root half `bazzite-mx-ntfsplus-setup`)
  writes the opt-in, loads the driver, then proves it before touching fstab: a 64 MB loop
  image formatted with `mkntfs`, mounted with `-t ntfs` and checked to be `ntfs` (not
  `fuseblk`), 8 MB and 20 directory entries written, unmounted, remounted, checksum compared.
  Only then the `ntfs3` rows of fstab become `ntfs` (type column alone, options untouched,
  backup `/etc/fstab.bazzite-mx-ntfsplus.bak`), `daemon-reload`, `findmnt --verify --fstab`,
  and each rewritten volume is unmounted and mounted again unless busy — a busy volume keeps
  its driver until the next boot; nothing is forced or lazily unmounted. `disable` is the
  exact reverse and unloads the driver when idle. The probe is there because of the v1
  failure shape below: a module built for the wrong kernel API dies at its first mount with
  vermagic and modinfo green, and fstab mounts fire at boot before the journal is on disk;
  the probe makes that first mount happen in a session, with fstab intact. Recovery after a
  boot panic: boot the previous deployment from the boot menu, `ujust setup-ntfsplus disable`.
- **Build guards**: the module's kbuild fragment is `obj-$(CONFIG_NTFS_FS) += ntfs.o`;
  against a kernel that leaves the symbol unset kbuild compiles nothing and exits 0
  (`MODPOST Module.symvers`, no `.ko`, measured 2026-09-04 on both kernels), so
  `source.env` carries `KO_BUILD_ARGS=CONFIG_NTFS_FS=m` and the builder puts it on the make
  line; `55-ntfsplus.sh` and its test assert the `fs-ntfs` alias, the blacklist directive,
  the four links gone, the alias unresolvable and the name resolvable to `updates/ntfs.ko`.
  The runtime mount is proven on the pilot host, never in the build (no kernel to load into).
- **What v1 did differently**: same module and helper removal, but no blacklist and no
  recipe — type `ntfs` in fstab was the switch, and the driver loaded on any `mount -t
  ntfs`. Two facts from that round still hold and are documented in [`gotchas.md`](gotchas.md):
  the two drivers agree on modes and case sensitivity (the mode bits come from the WSL
  metadata EAs, not the mask; both mount case-sensitive), and a `.N` bump of the pin needs
  the runtime proof.

## ujust recipes: the justfile feature (`70-justfile.sh`, `95-bazzite-mx.just`)

Criteria 1, 2, 3, 4; decision 1.5f (recipes with an upstream name replace the upstream
recipe, the base justfile modified in the build behind a guard), 1.5c (JetBrains Toolbox
kept as the v1 recipe, rewritten), 1.7 (a generic migration recipe for every host). Bazzite's
`ujust` is `just` on `/usr/share/ublue-os/justfile` (`ublue-os-just` 0.57), which imports
every file under `/usr/share/ublue-os/just/` by name and sets `allow-duplicate-recipes`.

- **How our recipes join**: `95-bazzite-mx.just` is appended as one more `import` line, the
  master file rewritten onto a fresh inode (the way bazzite-dx adds `95-bazzite-dx.just`,
  `build_files/60-clean-base.sh:5`, with `>>` there). Measured 2026-09-02 on just 1.57.0:
  with duplicate names across imports **the earlier import wins** (just manual, "Imports"),
  so an appended import can never override a base recipe. That is why a recipe of ours with
  an upstream name lives in the upstream file's place (`84-bazzite-virt.just`,
  `82-bazzite-sunshine.just`: rsync replaces the file) or, when the upstream file holds
  other recipes too, the upstream recipe is cut out of its file: `install-jetbrains-toolbox`
  from `82-bazzite-apps.just` (11 recipes in the base, 10 after; the block from its doc
  comment to its last body line, the file's other recipes proven unchanged by
  `just --summary`). The build fails if any name is defined in two files.
- **Drift guard** (2.5 #4.4 in spirit, decision 1.5f in letter): `00-prep.sh` records every
  base recipe file's recipe set before `system_files` is copied
  (`/usr/lib/bazzite-mx/build-state/just.base.summary`, 29 files on the 2026-09-02 base);
  `70-justfile.sh` refuses a replaced file whose set differs from ours and an override
  whose recipe the base no longer has, so a recipe upstream adds to `84-bazzite-virt.just`
  or renames in `82-bazzite-apps.just` stops the build instead of vanishing. `--self-test`:
  a recipe removed whole with its neighbours intact, an absent recipe refused, a removal
  that would orphan an `alias` refused, a drifted set refused.
- **`verify-host`** (invented name, after Bazzite's `verify-image` in
  `92-bazzite-verify.just`, which only rewrites the transport for `ghcr.io/ublue-os`):
  `/usr/libexec/bazzite-mx-verify-host` through sudo, one `OK:`/`FAIL:`/`SKIP:`/`INFO:`
  line per check, exit 1 on a FAIL. Checks: `bootc status` not `incompatible` (bootc
  `crates/lib/src/utils.rs:23-32`: any rpm-ostree group in the origin), origin
  `ostree-image-signed:docker://ghcr.io/matrixdj96/<the image's own name>:stable` (a dated
  tag never updates: 2.5 #4.2), no `packages`, `requested-packages`,
  `requested-local-packages`, `requested-base-removals`, `requested-modules` (the desktop's
  RPMs are local ones: 2.5 #2.11; an inactive request lives in `requested-packages` only,
  gotchas) and no `regenerate-initramfs`, the ghcr.io/matrixdj96 scope with its key and
  `registries.d` stanza in force and `default` still `reject`, `msi_ec` + `acpi_ec` loaded
  on a Micro-Star host, NVIDIA GPU (`lspci -d 10de:`) and flavour agreeing with the
  `nvidia` module loaded, every fstab NTFS row on `ntfs3` (or `ntfs` after `setup-ntfsplus`) and mounted as such, no v1 ntfsplus
  file or kernel argument; a Firefox Flatpak is reported (INFO), not failed: no Flatpak is
  required by the image. Positive control: run live on ldesktop-zrombi (v1 image,
  2026-09-02): 6 FAIL lines (incompatible, unsigned origin, `1password` layered, local
  initramfs, policy scope, registries.d), exit 1, as the design predicted; the smoke test
  replays a v1-state fixture (9 FAIL lines) and a migrated one (17 OK lines).
- **`migrate`** (invented name; design 2.4 called it `migrate-to-signed`):
  `/usr/libexec/bazzite-mx-migrate plan|apply [TAG]` through sudo, `TAG` default `stable`.
  Detect, then the steps of design 2.0 § 7, each behind `ugum confirm` and skipped when
  already done: local copies of `policy.json`/`registries.d` in `/etc` offered back from
  `/usr/etc` with a backup (2.5 #3d: the image's copy never arrives through the three-way
  merge), ABORT on a pending deployment (2.5 #3e) and on a booted image without the
  ghcr.io/matrixdj96 scope (the message gives the one-time unsigned rebase), backups under
  `/var/tmp/bazzite-mx-migrate/<timestamp>/`, `ostree admin pin booted`, `uupd.timer`
  stopped for the run, `rpm-ostree uninstall --all` (dry run shown first),
  `rpm-ostree initramfs --disable`, `rpm-ostree rebase ostree-image-signed:docker://…:TAG`
  (rpm-ostree, not `bootc switch`: visible, dry-run, and the resulting origin is the same,
  bootc `utils.rs:161-166`), fstab `ntfs` → `ntfs3` on the type column only after
  `ntfs3` is proven loadable (`/proc/filesystems`, else `modprobe -n`; 2.5 #4.3), zero
  `ntfs` rows after, `daemon-reload`, `findmnt --verify --fstab`, ntfsplus files and
  kernel arguments removed on confirmation (2.5 #5.4). Nothing is uninstalled from Flatpak
  (2.5 #5.1): the per-user Firefox profile copy, the Teams Flatpak, reboot, rollback and
  unpin are printed. `--self-test`: the fstab rewrite byte-exact outside the type column
  (comments and an `ntfs-3g` row untouched), a plan listing the steps on a v1-state
  fixture, refusals on a pending deployment, a missing scope and a local `policy.json`, a
  migrated fixture with every step skipped and the residue reported. `plan` run live on
  the hub (2026-09-02): the three steps listed, ABORT with the unsigned-rebase line, as
  expected on a v1 image.
- **Proven on the three hosts** (the hub first, then the two NVIDIA hosts, 2026-09-03/04): the
  signed rebase is accepted by the policy the v2 deployment carries (the end-to-end proof of the
  in-image trust), `bootc status` reports `incompatible: false`, the image's initramfs is 87 MB
  against the 252 MB a host regenerated, `verify-host` exits 0 on all three, the NTFS volumes
  mount with `ntfs3` (`findmnt --verify --fstab` warns "ntfs3 does not match with on-disk
  ntfs" on every rewritten row: a warning, exit 0). What the hosts surfaced, and the fixes
  each with its known-bad fixture: [`gotchas.md`](gotchas.md).
- **`setup-dev`**: `mise ls` (`status`) or, after seeding `~/.config/mise/config.toml`
  from `/etc/skel` when the account has none, `mise install` (mise CLI docs,
  `install`: "installs everything specified in mise.toml", read 2026-09-02). A global
  config with plain `[tools]` versions needs no `mise trust` ("safe config files do not
  require trust", mise docs `cli/trust`, read 2026-09-02; measured with the skel config
  on mise 2026.9.0: `mise ls` lists the four runtimes, no prompt).
- **`install-jetbrains-toolbox`** replaces Bazzite's, a Homebrew cask
  (`82-bazzite-apps.just:250-264`): `/usr/libexec/bazzite-mx-jetbrains-toolbox` reads
  JetBrains' release feed (`data.services.jetbrains.com/products/releases?code=TBA`,
  `.TBA[0].build`, `.downloads.linux.link`, `.checksumLink`; build 3.7.2.87231 on
  2026-09-02), downloads the tarball into `~/.cache/bazzite-mx/`, compares its sha256 with
  the feed's checksum file (a mismatch removes the download), unpacks it under
  `~/.local/share/JetBrains/ToolboxApp` and starts it once, which is JetBrains' documented
  Linux install (Toolbox App docs, "Installation", updated 2026-07-20: extract, run
  `./bin/jetbrains-toolbox`; first start initialises `~/.local/share/JetBrains/Toolbox`
  and the `.desktop` entry). No pin (Regola RPM); `--proto =https` on curl. The smoke test
  runs it on a `file://` feed with a synthetic tarball: good build installed and
  idempotent, wrong sha256 refused with nothing installed, tarball without the binary
  refused. The v1 recipe did the same download without caching and moved the tree with
  `rm -rf` while the app could be running; here a running Toolbox stops the install.
- Not carried over: the v1 `96-bazzite-mx-overrides.just` monolith (every other v1 recipe
  either returned as its own feature or was dropped with the feature).

## CI: two profiles, one build, no push (`build.yml`, `reusable-build.yml`)

Decisions 1.4 (shellcheck, shfmt, tests modelled on the base images), 1.5d (corrected and
precised: a push to `main` builds, rechunks and checks, and publishes nothing; `develop` is
the minimal sandbox; releases only from a dispatched workflow), 1.6 (action pins by commit
SHA, key reused). What differs from the family and why:

- **Profiles as inputs.** Bazzite's `build.yml` builds, rechunks, tests and pushes in one job
  gated on `github.event_name != 'pull_request'` (`build.yml:547-560`); aurora's
  `reusable-build.yml` takes `publish` as an input and conditions every publishing step on it
  (`reusable-build.yml:23-27`, `343-455`). Here `reusable-build.yml` takes `rechunk` (and,
  with the release workflow, `publish`): `develop` and PRs stop at the sandbox image, `main`
  composes and probes the chunked image and proves the signing key, and a dispatch runs the
  main profile on any ref. Nothing in `build.yml` reaches GHCR.
- **The chunked image is probed, not the raw one.** Bazzite runs goss on `localhost/chunked-img`
  (`build.yml:522-542`, `tests/dgoss/`), the only member of the family that executes the
  artefact it ships. Here `check-image.sh` does the same with the tools the image has: labels,
  `/run` and `/tmp` on the mounted image, `bootc container lint`, `rpm -q`, `modinfo`,
  `image-info.json`. goss would add a pinned binary for checks bash covers; the in-build smoke
  tests remain the place for per-feature assertions (2.5 #2.2).
- **One labels file.** `rpm-ostree compose build-chunked-oci --rootfs` produces a new config:
  the raw image's labels are not on the composed image unless passed again (bazzite
  `build.yml:407-420` builds the list with `ostree.bootable` and `ostree.linux`, `:442-458`
  passes it to compose; 2.5 #2.1). `image-labels.sh` is the one owner and both `podman build`
  and the compose step read its file; `check-image.sh` asserts every line on the artefact.
  Without labels of our own the image keeps the base's and calls itself Bazzite
  (`docs/gotchas.md`).
- **The signing key is proven on `main`.** No family repo does this: the secret is first used
  in the run that publishes. Here the main profile signs the chunked image's digest with
  `SIGNING_SECRET` (`cosign sign-blob`, no transparency log, no signing config: the bundle
  stays local) and verifies it with the `cosign.pub` the image trusts, then must refuse a
  tampered copy (cosign 3.1.3 `sign-blob`/`verify-blob`, flags measured 2026-09-02: `--bundle`
  is the only output form, `--output-signature` is deprecated). A rotated or mispasted secret
  fails on a push to `main`.
- **A lint job before the build.** The family runs no shellcheck, shfmt or yamllint in CI
  (design 2.2 § 1, checkouts of 2026-09-02); aurora and image-template check `.just` syntax
  (`Justfile:69-76`, `validate-just.yml:26-34`). Here `lint` gates `build`: shellcheck 0.11.0
  from the runner, shfmt 3.7.0 and yamllint from `quay.io/fedora/fedora:44` (the image's own
  release, so hook, CI and image format alike), `node --check` on the Plasma update scripts
  (a syntax error there is only a journal warning on the host, plasma-workspace
  `shellcorona.cpp:1153-1155`), `just --unstable --fmt --check` on every `.just` file with
  just from the runner's Linuxbrew (aurora `validate-just.yml:26-29`; `ublue-os/just-action@v3`
  is a moving tag, against decision 1.6), and the `--self-test` of every script under
  `.github/scripts/`.
- **Runner.** `ubuntu-26.04` for every job, explicit (the family: bazzite `build.yml`, aurora
  `reusable-build.yml:44`, image-template): the only runner with podman 5 and the only one
  whose kernel keeps in-place writeback (`docs/gotchas.md` § Torn writeback). `ubuntu-slim`
  has no container engine, no Homebrew and shellcheck 0.9.0 (2.5 #2.4).
- **Disk.** No space-freeing action. The `ubuntu-26.04` runner starts with 92 GB free of
  145 GB (`df` on run 33644315576, 2026-09-02) and the main profile needs the raw image, its
  OCI archive and the pulled chunked copy at once: 17 GB, 6.3 GB and 17 GB, the raw image
  removed before the pull (run 33645065090, 2026-09-02: 73 GB free before the compose, 85 GB
  before the pull, 74 GB after; the compose took 11.5 min, the pull 4 min). The family's
  `ublue-os/remove-unwanted-software` v9 (image-template `build-disk.yml:73`) fails on this
  runner (`apt-get remove powershell`, package absent: `docs/gotchas.md`); aurora and the
  template's `build.yml` pin an untagged commit of its `v10` merge instead. The compose step
  prints `df` before and after, so the margin stays measured.
- **`/run` in the image.** Bazzite empties `/run` and `/tmp` of the raw image with
  `buildah unshare` before the compose (`build.yml:431-437`). Here the build `RUN` mounts a
  tmpfs on `/run` (and `/tmp`), so the resolver file buildah binds there never reaches the
  image (`docs/gotchas.md`), and `check-image.sh` proves both directories empty on the
  artefact.

## CI: the release run (`release.yml`, `promote.yml`, `sign-image.yml`, `gate-release.sh`, `changelog.sh`, `refresh-pins.sh`)

Decisions 1.5d (a release only from a dispatched workflow), 1.5g (`44.<build date>`, `.N`
only on a same-day collision), 1.6 (key reused, `sigstoreSigned` policy, signature +
attestation + SBOM, SHA pins refreshed by a script in the repo, no bot), 1.1 (`:stable` moves
only onto a release a host has verified). What differs from the family and why:

- **The tag is born in a gate, by digest.** Bazzite and bazzite-dx push the dated tag and
  every alias from the build job, right after the push and before the signature (bazzite
  `build.yml:554-575`, bazzite-dx `build.yml:247-266`); aurora pushes `:staging`, signs it,
  then pushes the real tags from the same job (`reusable-build.yml:343-407`). Here the build
  job stops at `:staging` and hands the digest to a separate job as an artifact
  (`release-<flavour>.env`); `gate-release.sh` inspects `docker://<image>@<digest>`, checks
  title, vendor, `version` = release tag and `revision` = the run's commit, verifies the
  signature and the attestation, and only then copies the digest onto `:<tag>`. A `:staging`
  left by a failed run of the same day never reaches a tag (2.5 #2.7), and no tag ever points
  at an unsigned manifest. A `:<tag>` that already exists with another digest is refused: a
  release tag never moves (v1 `promote-release-tags.sh` warned and skipped; here it fails).
- **`:stable` has a switch.** No family repo distinguishes "publish" from "promote": their
  `:stable` moves on every run. Here the dispatch input `promote_stable` (default `false`)
  AND the repository variable `PROMOTE_STABLE` must both be true; otherwise the gate prints
  the reason and exits 0 (2.5 #1.1). `promote.yml` moves `:stable` onto a release a host has
  verified; the variable (`true` since 2026-09-03) lets the trigger and the watcher promote.
- **Negative controls in the gate.** `cosign verify` with `cosign.pub` and
  `gh attestation verify --repo MatrixDJ96/bazzite-mx` are first run on the flavour's own base
  at the digest the build pinned (`base.digest` label), signed and attested by ublue-os: cosign
  must answer with a signature-class rejection (either shape of `docs/gotchas.md`; any other
  failure is inconclusive) and the attestation lookup must find nothing. Lifted from v1
  `verify-published-signatures.sh` (akmods `verify-publication` pattern), extended to the
  attestation.
- **Attestation with `actions/attest`, `push-to-registry: false`.** Decision 1.6 names
  `attest-build-provenance`; its README (v4, read 2026-09-02) calls itself "simply a wrapper
  on top of actions/attest" and points new implementations at `actions/attest`, which bazzite
  (`build.yml:649`) and aurora (`reusable-build.yml:450`) use. The attestation stays in the
  GitHub store, where `gh attestation verify` reads it (aurora keeps `push-to-registry: false`
  with "this confuses cosign verify", `:454-455`; `true` is tried on a throwaway tag after the
  first release, 2.0 §10).
- **SBOM as a signed referrer, changelog from its diff, in bash.** As bazzite
  (`build.yml:476-497`, `:617-645`: syft on the exported root, `oras attach`, the referrer's
  digest signed). The release notes are `changelog.sh` (decision 1.4: bash), not
  `changelog.py`: the previous release comes from `gh release list` by `publishedAt`, never
  from the manifest's `RepoTags` (bazzite `changelog.py:254-281`; an orphan tag would hijack
  the comparison, v1 audit root R1); the package diff is `join` of the two RPM lists; a
  previous release without an SBOM (every v1 release) is stated in the notes and on stderr,
  never rendered as "no changes". Base version and kernel come from the labels of the exact
  base the image was built from (`base.name@base.digest`), not from a second `:stable` read.
- **One tag per run, taken tags probed on every package and the releases.** `release-tag.sh`
  reads `skopeo list-tags` of every package (a package never published answers `name unknown`
  and has no tag taken; § Three flavours) and `gh release list`; a probe that fails or
  returns nothing aborts (bazzite `build.yml:79-94` swallows the probe with `|| true` and would
  reuse a tag on a mute registry, v1 audit A.1). The Fedora major comes from the base's
  kernel label through `resolve-base.sh` (bazzite-dx `build.yml:89-109`), not from a constant.
- **No retry action, no release action.** `podman push` runs twice inside a three-attempt
  loop (podman#27796: the layer annotations land on the second push; bazzite-dx and aurora
  wrap it in `nick-fields/retry`), `gh release create --latest --target <sha>` replaces
  `softprops/action-gh-release` (aurora `generate-release.yml:65-77`): two pins fewer.
- **ORAS from its release, not from `setup-oras`.** The first release run (33697633900,
  2026-09-03 00:00Z) died on both flavours at `oras-project/setup-oras` v2.0.1 with "official
  ORAS CLI releases does not contain version 1.3.4": the action installs only the versions of
  the list embedded in its own release (`src/lib/data/releases.json`, up to 1.3.0 at v2.0.1;
  1.3.4 is on its `main` only), so a pin the release check calls current is not installable
  until the action itself is released again. `install-oras.sh` downloads the linux/amd64
  tarball and the checksums file of the ORAS release and refuses a tarball whose sha256 does
  not match (`--self-test`: a matching checksum accepted, a mismatch and a missing line
  refused; proven live on 1.3.4, 2026-09-03), `ORAS_VERSION` is the one input and
  `refresh-pins.sh` compares it with the ORAS releases, which is now also what installs. One
  action pin fewer (bazzite `build.yml:610` keeps `setup-oras`).
- **The recovery signer is restricted and closes on a verification.** bazzite-dx
  `sign_image.yml` signs whatever reference the dispatch names; here the reference must be one
  of the three images of this repository, is resolved to a digest first, and the signature is
  verified with `cosign.pub` before the job is green.
- **Pins refreshed by a script, five classes, offline self-test.** aurora runs renovate
  (`validate-renovate.yml`); decision 1.6 wants no bot. `refresh-pins.sh` reads the workflows
  and reports actions (sha and comment against the latest release, the sha proven to be a
  commit of that repository: GitHub docs "Security hardening for GitHub Actions"), binaries
  (`cosign-release`, `syft-version`, `ORAS_VERSION`), runner labels against the
  `actions/runner-images` README (the preview badge of `ubuntu-26.04` is reported, not
  hidden), the state of every workflow (`disabled_inactivity`: GitHub docs, events
  `schedule`) and the upstream issues the comments cite (a closed one means a flag is up for
  review). `--self-test` runs on fixture answers, offline, and covers every verdict. The
  live table on 2026-09-02 15:12Z: every pin `OK`, `ubuntu-26.04` "still marked preview",
  the three issues open.
- **Immutable releases.** A repository setting (GitHub docs "Immutable releases": the tag is
  locked to its commit, assets frozen, a release attestation generated; REST
  `PUT /repos/{owner}/{repo}/immutable-releases`), enabled on the repository (MEASURED
  2026-09-04) and listed in [`workflow.md`](workflow.md) § Repository settings.
- **Retention.** Dated tags are prunable like bazzite's and aurora's (`clean.yml`: 90 days,
  7 kept); the GitHub Release outlives its tag and says so.

Sources read 2026-09-02: GitHub docs "Reuse workflows" (permissions "can be only downgraded
(not elevated) by the called workflow"), "Immutable releases", REST "Repositories" (the
`immutable-releases` endpoints), `gh attestation verify` manual (`oci://` needs a registry
login; `--repo`, `--owner`), `actions/attest` README (inputs, permissions
`id-token`/`attestations`/`artifact-metadata`, `push-to-registry`), `actions/runner-images`
README (label table, preview badge) and `Ubuntu2604-Readme.md` (no cosign, syft or oras
preinstalled); releases and tags of every pinned action via `gh api` (table in the audit file
`2.1-ci-design.md` § 5, re-measured 15:12Z: unchanged; `actions/upload-artifact` v7.0.1
`043fb46d`, `actions/download-artifact` v8.0.1 `3e5f45b2`, `oras-project/oras` v1.3.4 added);
bazzite `build.yml` (version, push, SBOM, attest), `changelog.py`, `generate_release.yml`,
`sign_image.yml`; bazzite-dx `build.yml`, `sign_image.yml`; aurora `reusable-build.yml`,
`generate-release.yml`, `trigger-schedule-stable-image.yml`, `build-image-stable.yml`; v1
`verify-published-signatures.sh`, `promote-release-tags.sh`, `changelog.sh`, `sign-image.yml`
(read as reference, rewritten).

Sources read 2026-09-02: GitHub docs "Reuse workflows" (inputs typed, secrets by name,
"Permissions can only be maintained or reduced—not elevated—throughout the chain"),
"Workflow syntax" (`on.workflow_call.inputs.default`: a boolean input defaults to `false`,
a string to `""`), "Contexts" (`inputs` empty outside a dispatch or a call);
`rpm-ostree compose build-chunked-oci --help` (2026.2: `--rootfs` and `--from` mutually
exclusive, `--bootc` required, `--format-version 2` writes every parent directory,
`--max-layers` default 64); cosign 3.1.3 `sign-blob --help` and `verify-blob --help`;
`actions/runner-images` `Ubuntu2604-Readme.md` (kernel 7.0.0-1012-azure, Node.js 24.19.0,
Homebrew 6.0.19 not on `PATH`, Podman 5.7.0, Skopeo 1.21.0, yamllint 1.38.0, shellcheck 0.11.0).

## CI: the schedule, the watcher and the retention (`trigger-release.yml`, `watch-upstream.yml`, `clean.yml`, `watch-upstream.sh`)

Decisions 1.5d (a release from a weekly cron "tipo aurora", an upstream watcher every 6 h, a
manual dispatch; never from a push), 1.5g (cleanup as a weekly cron in the bazzite/aurora
form, thresholds declared, aliases excluded, dry run read before the cron is armed), 1.5c (bazzite-63
7b5f68f: a poll every 6 h). What differs from the family and why:

- **The trigger keeps `release.yml` on one event.** Aurora's
  `trigger-schedule-stable-image.yml` exists because its release branch is not the default
  ("we can't schedule builds on non-default branches"); ours is `main`, where a `schedule`
  would run ("Scheduled workflows run on the latest commit on the default branch", GitHub docs,
  events `schedule`, read 2026-09-02). The trigger stays because `release.yml` then has a
  single trigger, `workflow_dispatch`, for the cron, the watcher and the owner: no `if:` on
  the event inside the jobs, and the `reason` input in the run name is what the watcher
  coalesces on. The minutes are off `:00` (`20 3 * * 2`, `37 */6 * * *`): "the schedule event
  can be delayed during periods of high loads [...] High load times include the start of every
  hour" (same page). A dispatch from `GITHUB_TOKEN` creates the run ("workflow_dispatch and
  repository_dispatch events always create workflow runs", GitHub docs "Triggering a workflow
  from a workflow"); the boolean input travels as the string `true` (`-f rechunk=true` on
  `build.yml` ran the main profile on run 33648149093, 2026-09-02).
- **The watcher compares digests, through the labels our build writes.** bazzite-dx reads the
  base's `org.opencontainers.image.version` (`build.yml:89-98`); v1 compared the tag recorded in
  `base.name`. Here `watch-upstream.sh` compares the digest of `ghcr.io/ublue-os/<base>:stable`
  (`resolve-base.sh`, the one owner of the coordinates) with the `base.digest` label of our own
  `:stable`, per flavour: a retag or a `.N` rebuild upstream moves the digest and not the
  version. The base carries no `base.*` label (measured 2026-09-02); `image-labels.sh` writes
  both on every image. Fail-closed as in v1 and stricter: a base that cannot be resolved, an
  image that cannot be inspected or a `:stable` without the label exit 1 and the run is red
  (refutation 4.1: a missing label read as "stale" would produce a green release every 6 h); a
  `:stable` that does not exist (`manifest unknown`) is `absent`, nothing to compare.
- **The variable, not the absence of `:stable`, gates the crons.** The design (2.0 § 6) counted
  on "our `:stable` absent = no dispatch"; `:stable` exists on `bazzite-mx` and
  `bazzite-mx-nvidia-open` and carries the `base.digest` of the current base (MEASURED
  2026-09-02 15:26Z; `bazzite-mx-nvidia` has none until its first release, and one absent
  image beside current ones is still `current`), so an upstream move would
  produce a release the gate cannot promote, one per day. `decide` refuses the dispatch while
  the repository variable `PROMOTE_STABLE` is not `true`; the trigger job carries the same
  condition as an `if:`. The variable is the switch on both sides: it lets the gate move
  `:stable` and it lets the crons create releases.
- **Coalescing on the run name.** One dispatch per run even when every flavour is stale (one
  run builds both); none while a release run is queued or in progress, and none when a
  release with the same `reason` completed in the last 24 h, whatever its conclusion: a
  stable failure is rebuilt once a day, not four times, and a success whose promotion the
  gate skipped is not repeated (2.1 § 3). The runs come from the repository-wide endpoint
  filtered on the workflow's path, because the per-workflow endpoint answers 404 while the
  file is not on the default branch (`docs/gotchas.md`). The reason is
  `upstream:<12 hex>+<12 hex>`, one short digest per base, so the same upstream state always
  produces the same run name.
- **The retention names its packages.** bazzite and aurora list their packages literally
  (`clean.yml:23`, `:19`); the design (2.0 § 6) planned anchored regular expressions on
  `packages` so that `bazzite-mx` could not match another package of the owner. The
  action's source says `packages` is a plain list unless `expand-packages` is set, which needs
  a classic PAT and turns the whole string into one regular expression (`docs/gotchas.md`), so
  the literal list `bazzite-mx,bazzite-mx-nvidia-open,bazzite-mx-nvidia` is both the simpler and the only form
  that works with `GITHUB_TOKEN`; a literal name cannot match another package. `use-regex`
  stays for `exclude-tags: ^(stable|staging)$` (v1 also spared `latest`, `stable-44` and the
  `testing*` aliases, which v2 does not emit). Thresholds as bazzite (`older-than: 90 days`,
  `keep-n-tagged: 7`, `keep-n-untagged: 7`, `delete-orphaned-images: true`), plus
  `validate: true`. The dated tags are prunable, as in the family; the GitHub Release outlives
  them and says so. `dry_run` defaults to `true` on a dispatch; the weekly cron (Sundays
  00:15 UTC, the family's slot) deletes for real (decision 1.5g); a dry run is read before
  any change to its parameters.
- **Exercised so far.** The watcher's `stale` branch and the cleanup's deleting branch have run
  only in their self-tests and dry runs (no base moved while the watcher watched; nothing older
  than 90 days yet); a first real run is read like any first run.
- **Runners.** The trigger and the cleanup run on `ubuntu-slim` (Node.js 24, GitHub CLI 2.96,
  jq; `ubuntu-slim-Readme.md`, image 20260728.2.1, read 2026-09-02): nothing there needs a
  container engine. The watcher needs skopeo and runs on `ubuntu-26.04`.

Sources read 2026-09-02: GitHub docs "Events that trigger workflows" § schedule (default
branch, high-load delay, 60-day disabling, 5-minute minimum), "Triggering a workflow from a
workflow", REST "Workflow runs" (`GET /repos/{owner}/{repo}/actions/runs` with `event`,
`status`, `created`; the per-workflow endpoint by file name), `gh workflow run` manual (`-f`,
`--ref`, the workflow by file name); `dataaxiom/ghcr-cleanup-action` README (inputs,
`expand-packages`, token setup) and `src/main.ts`, `src/config.ts` at v1.2.2; runner-images
README (`ubuntu-slim` row) and `ubuntu-slim-Readme.md`; aurora
`trigger-schedule-stable-image.yml`, `clean.yml`; bazzite `clean.yml`; v1 `watch-upstream.yml`,
`clean.yml` (read as reference, rewritten).

## The landing page (`site/index.html`, `deploy-pages.yml`, `check-site.sh`)

Decision 1.5e (one page: the switch commands and the signature check; the full site returns
when v2 is stable), 1.6 (action pins by SHA). What differs from v1 and why:

- **One file, no build.** v1's page was 41 KB of markup with two web fonts and four SVG
  assets, animated, and it still advertised `:testing`, `:latest`, the closed-driver flavour
  and an hourly rebuild after all four were gone. Here `site/index.html` is one hand-written
  file: the three images and their bases, the dated tags and what `:stable` means, the four
  commands that move a Bazzite host (unsigned rebase, reboot, `ujust migrate apply`,
  `ujust verify-host`: the chicken-and-egg of the signed transport is stated on the page,
  [`migration.md`](migration.md) has the rest), `cosign verify` with the repository's key and
  `gh attestation verify` (the manual's note that an `oci://` reference needs a registry
  login, read 2026-09-02: `gh` reads the Docker credential keychain, cli/cli
  `pkg/cmd/attestation/artifact/oci/client.go:55-57`), and three links into the docs. System
  fonts, a light and a dark palette through `prefers-color-scheme`, no script.
- **The page is checked before it is published, and on every sandbox run.** No family repo
  checks its page (bazzite's site is a separate repository; aurora and bazzite-dx have none).
  `check-site.sh` refuses: a symbolic or hard link in `site/` ("The tar file ... should not
  contain any symbolic or hard links", GitHub docs "Using custom workflows with GitHub
  Pages"), markup that is not well-formed (the page is written as XML on purpose, so
  Python's expat is the parser: on `ubuntu-slim` 20260728.2.1 and `ubuntu-26.04`), a page
  that does not name the three images (each as a whole name: `bazzite-mx-nvidia` inside
  `bazzite-mx-nvidia-open` does not count) or the public key, any of `:testing` and
  `:latest`, and a dead link: a link into this repository
  (`blob/main`, raw `main`) must be a file of the checkout, so the page and the file ship in
  the same push and the check holds while the branch is not yet on `main` (the first live run,
  2026-09-02 17:15Z, was red on `docs/migration.md`, which v1's `main` does not have: the
  positive control, before the repository links were resolved on the checkout); every other
  link is fetched. `--self-test`: one good page accepted, six lesions refused. The self-test
  runs in the lint job, the live check in the lint job and in `deploy-pages.yml` before the
  upload.
- **The workflow is the starter's, pinned.** GitHub's `starter-workflows/pages/static.yml`
  and the docs' custom-workflow page: `configure-pages`, `upload-pages-artifact` (a composite
  step: GNU `tar --dereference --hard-dereference` of the directory, then
  `actions/upload-artifact`, `action.yml` at v5.0.0), `deploy-pages` in the `github-pages`
  environment with `pages: write` and `id-token: write`; `contents: read` for the checkout;
  the group `bazzite-mx-pages` with `cancel-in-progress: false` (the starter's comment: a
  production deployment is never cancelled). Pins measured 2026-09-02 17:08Z:
  `configure-pages` v6.0.0 `45bfe019`, `upload-pages-artifact` v5.0.0 `fc324d35`,
  `deploy-pages` v5.0.1 `368f8252` (released 2026-09-01); `refresh-pins.sh --check` reports
  all three `OK`. Runner `ubuntu-slim`: the actions run on Node.js 24 and the step
  needs tar, python3 and curl, all there (`ubuntu-slim-Readme.md`). Trigger: a push to `main`
  that touches `site/`, the check or the workflow, or a dispatch; no schedule (the page has no
  reason to change on its own) and no run on any other branch: the repository's Pages source is
  "GitHub Actions" (`build_type: workflow`, `gh api .../pages`, 2026-09-02).
- **Deployment.** The first `Deploy Pages` run followed the first push of this tree to `main`,
  dispatched by hand (a force-push of an unrelated history creates no `push` run,
  `docs/gotchas.md`); since then every push to `main` that touches `site/`, the check or the
  workflow deploys, and the check runs first.

Sources read 2026-09-02: GitHub docs "Using custom workflows with GitHub Pages" (the three
actions, permissions, the `github-pages` environment, the artifact's tar rules),
"Configuring a publishing source for your GitHub Pages site" (source "GitHub Actions");
`actions/starter-workflows` `pages/static.yml`; `actions/upload-pages-artifact` README and
`action.yml` at v5.0.0, `actions/deploy-pages` README and `action.yml` at v5.0.1,
`actions/configure-pages` `action.yml` at v6.0.0 (all `node24`); `gh attestation verify`
manual; cli/cli `pkg/cmd/attestation/artifact/oci/client.go`; runner-images
`ubuntu-slim-Readme.md` (image 20260728.2.1) and `images/ubuntu-slim/Dockerfile`
(`FROM ubuntu:24.04`); v1 `site/index.html` and `deploy-pages.yml` (read as reference,
rewritten).
