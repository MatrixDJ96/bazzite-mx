# Divergences from Bazzite

What this image changes over its base, one entry per feature. A change enters only when
upstream does not cover it, it needs the image layer, a host that runs the image uses it and it
ships a smoke test. Each entry says what the image does, why, where the claim comes from and
which files carry it; the guards themselves live in the build script and its test.
[`gotchas.md`](gotchas.md) holds the surprises this project probed, each with its date.

Contents: three flavours · image identity · signing trust · hook framework · Docker CE ·
virtualization · VS Code · git tools · command-line tools · mise · desktop applications · the
cleaned stage · CI.

## Three flavours, one recipe

Bazzite's KDE desktop images come one per graphics stack: `bazzite` for AMD and Intel,
`bazzite-nvidia-open` for the open kernel modules and `bazzite-nvidia` for the closed driver.
This image follows all three, and the base image and the name it maps to are the only
differences between them. A host reaches the changes below only through an image built on its
own stack's base. The recipe therefore stays one file with `BASE_IMAGE` and `IMAGE_NAME` as its
variables, and `resolve-base.sh` maps a flavour to a base image and pins it to a digest. The
closed-driver base carries a kernel of its own. Source: `bazzite`'s
`.github/workflows/build.yml`, the image matrix of the `push-ghcr` job, where the closed-driver
images, `bazzite-nvidia` and its GNOME twin, take the `ogc-lts` kernel.

Every enumeration of the three images is literal: `FLAVOURS` and `image_of` in
`.github/scripts/lib.sh` and the build matrix name them one by one; `resolve-base.sh --digests`
loops over `FLAVOURS`.

Files: `Containerfile`, `.github/scripts/resolve-base.sh`, `.github/scripts/lib.sh`.

## Image identity and the update ref

A layer built on Bazzite keeps Bazzite's identity until something rewrites it, and the identity
is not cosmetic: `image-ref` in `/usr/share/ublue-os/image-info.json` is what Bazzite's shell
greeting (`/usr/share/ublue-os/motd/env.sh`) prints as the host's image, so an unrewritten file
calls the host `ghcr.io/ublue-os/bazzite`. Bazzite's rollback helper reads `image-name` too:
`brh rebase <tag>` builds `ghcr.io/ublue-os/<image-name>:<tag>`, a repository that does not
exist for this image. The image a host pulls from at `bootc upgrade` is the deployment's
origin, which `bootc status` prints. The build writes `image-name`, `image-vendor`,
`image-ref`, `version`, `version-pretty` and `base-version` there, `base-version` keeping the
base's own `version`; `VARIANT_ID` and `IMAGE_ID` in `/usr/lib/os-release`, the identity
os-release(5) gives an image; and `Variant` and `Website` in `/etc/xdg/kcm-about-distrorc`, the
KDE About page, the variant naming the flavour. Sources: os-release(5), bootc's upgrade
contract (https://bootc-dev.github.io/bootc/), Bazzite's own `image-info.json` and
`/usr/bin/bazzite-rollback-helper`.

Files: `build_files/10-image-info.sh` and its test.

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
converges at every boot or login: the group memberships the container runtime and libvirt need,
and the VS Code extensions of each account. `ublue-setup-services` comes from the COPR
`ublue-os/packages`, the way bazzite-dx installs it
(`bazzite-dx/build_files/20-install-apps.sh`) and enables it
(`bazzite-dx/build_files/40-services.sh`). Only the system unit is enabled here;
`ublue-user-setup.service` is enabled `--global` by the IDE feature, the first one with a user
hook. Our hooks converge instead of stamping a version. bazzite-dx gates the same work behind
libsetup's `version-script`
(`bazzite-dx/system_files/usr/share/ublue-os/privileged-setup.hooks.d/20-dx.sh`), which records
the run before the body executes: it never repeats a failed run and never reaches an account
created later.

The package also drops a polkit action and rule of its own into `/etc`, letting any local user
run `/usr/libexec/ublue-privileged-setup` as root without authentication
(`org.ublue.policykit.privileged.user.setup`, `allow_any=yes`). The privilege is accepted for
what it dispatches: this image ships no `/usr/share/ublue-os/privileged-setup.hooks.d`, so the
program runs nothing. The program reads the hooks directory from the file `SETUP_CONFIG_FILE`
names, `/etc/ublue-os/setup.json` by default, and `pkexec` hands it a minimal environment in
which that variable does not survive (`pkexec(1)` § SECURITY NOTES), so the file read is
root's. Source: the package's own files in the COPR `ublue-os/packages`.

The package also ships a Secure Boot key notice, and the build removes it:
`/etc/profile.d/sbkey-notify-autostart.sh` copies
`/etc/skel/.config/autostart/sb-key-notify.desktop` into `~/.config/autostart` of every account
but root at each login shell, and the entry names `/usr/bin/sb-key-notify`, which the package
ships mode 0644. Plasma starts autostart entries through `systemd-xdg-autostart-generator`
(`systemdBoot=true` in `/etc/xdg/startkderc`), which refuses this one with a warning
(`not generating unit, error parsing Exec= line: Permission denied`) at each start of a user
manager, the greeter's `plasmalogin` included, so the notice never shows. It would show only
when `/run/user-motd-sbkey-warn.md` exists, which `/usr/libexec/check-sb-key.sh` writes from
`check-sb-key.service`, disabled here. The build deletes the login script and the skel entry; a
copy an earlier image left in a home stays there, warning, until
`rm ~/.config/autostart/sb-key-notify.desktop`. Source: the same files of the package, and
systemd's `src/xdg-autostart-generator/xdg-autostart-service.c`, which logs that warning for an
`Exec=` binary it cannot execute.

Files: `build_files/20-setup-services.sh` and its test,
`system_files/usr/share/ublue-os/system-setup.hooks.d/10-bazzite-mx-groups.sh`.

## Docker CE

Bazzite ships podman only, and the hosts here run Docker for devcontainers and compose. The
pattern is bazzite-dx's (`bazzite-dx/build_files/20-install-apps.sh`), rewritten. The five
packages of https://docs.docker.com/engine/install/fedora/ come from a vendored repository with
`enabled=0` and `gpgkey=file://`, its fingerprint asserted before the first install. bazzite-dx
instead fetches the file at build time and disables it with a `dnf5 config-manager setopt`, a
silent no-op on a repository added from a file. `docker.socket` is enabled and `docker.service`
left to socket activation, `podman.socket` with it, and `podman-machine`, `podman-tui`,
`podman-compose` and `bcvk` come from Fedora in the same script; `bcvk` requires `qemu-kvm` and
`qemu-img`, so the QEMU stack enters the image here, before the virtualization script.

Two host-level effects need the image layer. `iptable_nat` is listed in `modules-load.d` for
docker-in-docker, whose inner dockerd cannot load kernel modules itself
(devcontainers/features#1235, ublue-os/bluefin#2365). The `docker` group, created ahead of the
packages (below), is moved to `/usr/lib/group` by `95-clean-stage.sh` (§ The cleaned stage),
where NSS resolves it through `altfiles`. That relocation keeps
`bootc container lint --fatal-warnings` green, its sysusers check refusing a group line in
`/etc/group`. The boot hook copies the line back and adds every wheel member, which grants
root-level privileges (https://docs.docker.com/engine/install/linux-postinstall/), the
bazzite-dx choice, kept because the fleet's wheel users administer their own machines. One
residual: the `%post` loads an SELinux module only where `selinuxenabled` answers true, which
it does not in a build container, so hosts run without that AF_ALG denial. The boot hook only
adds: an account taken out of wheel, as KDE's Users page does to an administrator made Standard
(accountsservice, `src/user.c`), keeps `docker` and `libvirt` until
`sudo gpasswd -d <user> docker` and `sudo gpasswd -d <user> libvirt`. Both groups are allocated
dynamically: the `%post` of `docker-ce` runs `groupadd --system`, libvirt's sysusers file reads
`g libvirt -`, and the `uidgid` table of `setup` has neither, its packaging guidelines giving a
fixed number only to ids shared between machines (Fedora Packaging Guidelines, «Users and
Groups»). A host's `/etc/group` can so keep another number than the image's, and a `libvirt`
line Bazzite's `virt-on` added with `groupadd --system` (its `84-bazzite-virt.just`) can hold
the gid `docker` has in `/usr/lib/group`, every member of that `libvirt` then opening the
Docker socket. The image fixes `docker` at 995 and `libvirt` at 954, the numbers the
`bazzite-mx` build gave them, created ahead of the packages from
`/usr/lib/sysusers.d/bazzite-mx-groups.conf`, and the boot hook moves a group of `/etc/group`
on another number to the image's when no other group holds it, the files under `/run`
(`docker.sock`), `/etc` and `/var/lib/libvirt` with the old gid following; the homes and the
container stores are left, their files carrying gids of their own in the same range. The
standards of other distributions fall in Fedora's static range: Gentoo's 48 and 79
(`api.gentoo.org/uid-gid.txt`) and NixOS's 131 and 67 (`nixos/modules/misc/ids.nix`), 48 and 67
being `apache` and `webalizer` in `uidgid`.

Files: `build_files/21-container-runtime.sh` and its test, `build_files/01-system-files.sh`,
`system_files/usr/lib/sysusers.d/bazzite-mx-groups.conf`,
`system_files/etc/yum.repos.d/docker-ce.repo`,
`system_files/etc/pki/rpm-gpg/RPM-GPG-KEY-docker-ce`,
`system_files/usr/lib/modules-load.d/ip_tables.conf`,
`system_files/usr/share/ublue-os/system-setup.hooks.d/10-bazzite-mx-groups.sh`.

## Virtualization and quickemu

Bazzite ships `edk2-ovmf` and the `kvmfr` module but no libvirt, QEMU or virt-manager: its
`setup-virtualization` recipe installs the virt-manager Flatpak and enables the monolithic
`libvirtd` per host. The hosts here run local VMs, so the stack belongs in the image, as an
explicit package list on the modular daemons (weak dependencies are off in the base's
`dnf.conf`; https://libvirt.org/daemons.html) that Fedora 44's own preset enables
(`/usr/lib/systemd/system-preset/90-default.preset`). The build asserts `virtqemud.socket`
enabled and `libvirtd.service` disabled, so a preset change stops the build, and the
virt-manager Flatpak is denied through the base's Flatpak filter, the RPM being in the image.

The preset enables more than the QEMU pair. `libvirt` is a metapackage, and the drivers it
brings arrive with the preset lines that start them: `virtqemud`, `virtxend`, `virtlxcd` and
`virtvboxd` are all enabled on a host, service (`90-default.preset:73-76`) and socket
(`:80-91`), while `virtchd` and the monolithic `libvirtd` stay disabled. The LXC, Xen and
VirtualBox daemons have nothing to drive on these hosts and are accepted rather than trimmed:
they are the packaging's own shape, and a hand-picked driver list would have to be revisited at
every base bump. The storage drivers bring an iSCSI initiator with them
(`iscsi-initiator-utils`, `libiscsi`, `lsscsi`), whose `iscsid.socket`, `iscsiuio.socket`,
`iscsi-starter.service` and `iscsi-onboot.service` the same preset enables
(`90-default.preset:145-153`); accepted for the same reason, the sockets listening on the host
alone. `quickemu` has the same shape: it requires the `qemu` metapackage, which requires every
`qemu-system-*` and `qemu-user` (`rpm -q --requires qemu`), so the image carries the 17
emulators of other architectures, `qemu-user` and their firmware (`edk2-aarch64`,
`edk2-loongarch64`, `edk2-riscv64`, `openbios`, `SLOF`), 954 MiB installed that nothing else
asks for; accepted as the packaging's shape too. quickemu forwards the guest's port 22 on
`0.0.0.0:22220` and up (its `hostfwd=tcp::${ssh_port}-:22` names no host address,
`/usr/bin/quickemu`), which the `FedoraWorkstation` zone admits, so a guest running `sshd` is
reachable from the LAN while it runs.

Four smaller choices go with it. `ublue-os-libvirt-workarounds` from the same COPR handles the
`restorecon` of `/var/{lib,log}/libvirt` at boot, and a tmpfiles file recreates the `/var`
directories the packages ship, rpm-ostree's autovar mechanism not recovering directories a
build removed. The KVM options Bazzite adds as kernel arguments are set in `modprobe.d`
instead, `kvm` being a module in the ogc kernel. quickemu needs `mesa-demos`, which the base's
`exclude=mesa-*` filters out because Mesa comes from Terra. The build lifts that exclude for
that one package and proves no other `mesa-*` package moved. The `libvirt` group reaches wheel
members through the boot hook, like `docker`.

Docker CE and libvirt share the host's forwarding path, and dockerd sets the iptables `FORWARD`
policy to `DROP` when it enables IP forwarding itself as it starts
(https://docs.docker.com/engine/network/packet-filtering-firewalls/ § Docker on a router).
libvirt 12 writes its network rules with its nftables backend, in a table of its own: they
accept a NAT guest's packets, Docker's policy then drops them, and a VM on the `default`
network reaches the host and nothing beyond ([`gotchas.md`](gotchas.md) § Docker's `FORWARD`
policy cuts libvirt's NAT guests off). Docker documents one ACCEPT per interface pair in its
`DOCKER-USER` chain as the way to forward between host interfaces
(https://docs.docker.com/engine/network/firewall-iptables/ § Allow forwarding between host
interfaces): a drop-in on `docker.service` runs `bazzite-mx-libvirt-forward` once dockerd is
ready. The helper keeps its rules in a chain of its own, `BAZZITE-MX-LIBVIRT`, emptied and
refilled at every run so their order never depends on what an earlier run left, and makes
`DOCKER-USER` jump to it once: a guest's packet to a Docker bridge (`docker0`, `br-*`) returns
to Docker's own rules, which admit a published port and drop the rest, the way they treat any
remote host; any other packet from a `virbr+` bridge is accepted, libvirt's own chains still
rejecting what a network does not allow; a packet to a `virbr+` bridge is accepted only as the
reply of a connection the guest opened. A plain `-i virbr+ -j ACCEPT` would have skipped
Docker's ingress rules for every container. A daemon that writes no iptables rules (`iptables`
off, or the nftables backend) has no `DOCKER-USER` chain and sets no DROP policy, and the
helper says so and exits 0; a read of that chain or a check of the jump that fails for any
other reason (iptables-nft's `Could not fetch rule set generation id` under a concurrent
writer), or a rule that cannot be written, is an `ERROR:` line in the journal and exit 1, which
the `-` prefix of the `ExecStartPost=` keeps from failing `docker.service`; on a read or a
check it cannot trust the helper writes nothing, so no second jump accumulates. Docker never
flushes `DOCKER-USER`, and the drop-in re-runs the helper at every start. The other documented
route, `ip-forward-no-drop` in `daemon.json`, lifts the policy for every interface of the host
and was not taken. IPv6 is out of scope: the `default` network has none and Docker leaves the
`ip6tables` policy at ACCEPT.

The recipe `setup-virtualization` replaces Bazzite's file of the same name, and the Portal's
virtualization group, whose `virt-on` and `virt-off` it does not have, is removed. It reports
status and runs the kvmfr setup, bazzite-dx's helper (commit a0f3842) in the form of
`conventions.md` § Bash → Form: the same steps in the same order with the same text, one
function per step, `set -euo pipefail`, and one shellcheck directive: the bold codes its notice
prints, `b` and `n`, are readonly names of `ujust.sh`'s own `libformatting.sh`, which
shellcheck cannot follow on a runner, and a copy that assigned them failed at every run
([`gotchas.md`](gotchas.md) § `ujust.sh` declares its colour and formatting names readonly).
Upstream's `qemu.conf` edit is not carried: it matches the commented `cgroup_device_acl` block
of a libvirt this base does not ship, so it wrote nothing on any host
([`gotchas.md`](gotchas.md) § The kvmfr helper's `qemu.conf` edit matches nothing on this
base). Not carried over: Bazzite's enable and disable switches, whose work the image already
does: `libvirtd` as the modular daemons, the Flatpak as the RPM, the kernel arguments as
`modprobe.d` options, `/var/lib/swtpm-localca` and the `restorecon` as the tmpfiles file and
the workarounds unit, the `libvirt` membership as the boot hook. The build removes the base's
`bazzite-libvirtd-setup.service`, which Bazzite's `virt-on` enables and which would enable and
start the monolithic `libvirtd` at the first boot of a host that ran `virt-on` before it came
to the image. The recipe's help (`ujust setup-virtualization help`) gives the kvmfr undo, which
frees the 128 MiB the module holds at every boot.

Files: `build_files/22-virtualization.sh` and its test, `build_files/lib/flatpak.sh`,
`build_files/lib/just.sh`, `system_files/usr/lib/modprobe.d/bazzite-mx-kvm.conf`,
`system_files/usr/lib/tmpfiles.d/bazzite-mx-virt.conf`,
`system_files/usr/share/ublue-os/just/84-bazzite-virt.just`,
`system_files/usr/libexec/bazzite-dx-kvmfr-setup`,
`system_files/usr/libexec/bazzite-mx-libvirt-forward`,
`system_files/usr/lib/systemd/system/docker.service.d/bazzite-mx-libvirt.conf`.

## Visual Studio Code

The RPM from Microsoft's repository, so the editor follows the image instead of updating itself
per user. bazzite-dx fetches Microsoft's `config.repo` at build time with `gpgcheck=0`
(`bazzite-dx/build_files/20-install-apps.sh`); here `vscode.repo` is vendored with the stanza
https://code.visualstudio.com/docs/setup/linux gives, the key ships in the image and its
fingerprint is asserted before the install. The skel `settings.json` sets `update.mode` to
`none`, the FAQ's switch for the editor's own update check
(https://code.visualstudio.com/docs/supporting/faq); on Linux the repository owns the updates.

The user hook seeds those settings for accounts that predate the image and installs the
containers, remote-containers and remote-ssh extensions when
`~/.vscode/extensions/extensions.json` lacks them. It runs at every login and keeps no version
stamp, so an account created later is picked up, and its check reads that file rather than
spawning the editor. With an extension missing it first waits up to a minute for the network:
the unit's `After=network-online.target` names a target the user manager does not have
(systemd.special(7) § Special User Units), so a session opened at boot can start before it. An
extension that still fails to install is retried at the next login. What the user removes comes
back the same way: an uninstalled extension is installed again and a deleted `settings.json`
seeded again at the next login, so an unwanted extension is disabled rather than uninstalled,
and the settings file emptied rather than deleted.

Files: `build_files/30-ide.sh` and its test, `system_files/etc/yum.repos.d/vscode.repo`,
`system_files/etc/pki/rpm-gpg/RPM-GPG-KEY-microsoft`,
`system_files/etc/skel/.config/Code/User/settings.json`,
`system_files/usr/share/ublue-os/user-setup.hooks.d/11-bazzite-mx-vscode-extensions.sh`.

## Git tools

GitKraken as an RPM in the image rather than a Flatpak, the owner's choice, plus
`git-credential-libsecret` from Fedora, which pulls the full `git` package over the base's
`git-core`: the perl-backed subcommands (`git send-email`, `git svn`, `git difftool`) are on a
host for that reason. GitKraken publishes one fixed URL,
https://release.gitkraken.com/linux/gitkraken-amd64.rpm, which redirects to whatever release is
current, so nothing is pinned. The RPM carries no OpenPGP signature and no scriptlets, so the
build checks its payload digests with `rpm -K --nosignature` and installs it with
`--no-gpgchecks` for that one local file. Its only dependency, `libXScrnSaver`, is in the base.

Files: `build_files/31-git-tools.sh` and its test.

## Command-line tools

`gh`, `glab`, `ShellCheck` and `shfmt`, plus the fourteen further packages `32-cli-rpms.sh`
installs in one transaction: the tracing and profiling set (`bcc`, `bcc-tools`, `bpftop`,
`bpftrace`, `iotop-c`, `nicstat`, `numactl`, `sysprof`, `trace-cmd`) and `android-tools`,
`ccache`, `flatpak-builder`, `ripgrep` and `telnet`. All are Fedora 44 packages and none is in
the base; bazzite-dx and aurora carry most of the same names
(`bazzite-dx/build_files/20-install-apps.sh`, `aurora/build_scripts/dx/00-dx.sh`). Fedora's
`shfmt` is the release CI and the edit hook format with, so image, hook and CI agree on the
formatter and no formatting diff is meaningless ([`conventions.md`](conventions.md)).

`ccache` ships `/etc/profile.d/ccache.sh`, which puts `/usr/lib64/ccache` first in the `PATH`
of every login shell, so `gcc`, `cc`, `g++` and `c++` run through ccache for every account. The
shared cache the script prefers, `/var/cache/ccache`, has no tmpfiles line and does not exist
on a host, so each account keeps its own. Source: the package's own file.

Files: `build_files/32-cli-rpms.sh` and its test.

## mise

`mise` manages per-user language runtimes. Its binary comes from the COPR its own documentation
names (https://mise.jdx.dev/installing-mise.html), so it is the same on every host and needs no
first-login install. The repository is vendored with `enabled=0`, the project key ships in the
image and its fingerprint is asserted before the install.

`/etc/profile.d/mise.sh` runs `mise activate bash` in login and interactive bash: a login
shell, interactive or not, reads `profile.d` through `/etc/profile`, an interactive non-login
one through Fedora's `/etc/bashrc`, which `~/.bashrc` sources. The skel
`~/.config/mise/config.toml` names node lts, python 3.14, java temurin-21 and dotnet 10; the
runtimes themselves are installed per user with `mise install`, never in the image. Only bash
gets mise activated by the image; a fish account adds
`if type -q mise; mise activate fish | source; end` to `~/.config/fish/config.fish`. The
package ships the bash and fish completions.

Files: `build_files/33-mise.sh` and its test, `system_files/etc/profile.d/mise.sh`,
`system_files/etc/skel/.config/mise/config.toml`, `system_files/etc/yum.repos.d/mise.repo`,
`system_files/etc/pki/rpm-gpg/RPM-GPG-KEY-copr-jdxcode-mise`.

## Desktop applications

**Firefox.** Bazzite removes `firefox` and `firefox-langpacks` in favour of the Flatpak. The
RPM is back because of 1Password's browser integration: native messaging goes through
`/opt/1Password/1Password-BrowserSupport`, a host binary a sandboxed Firefox does not reach out
of the box. The Flatpak is denied through Bazzite's own filter: `bazzite-flatpak-manager`
points Flathub's filter at its blocklist with `flatpak remote-modify --filter` when its version
or the image name changes, as the rebase onto this image does, and the remote reads the file by
path (flatpak-remote-modify(1), flatpak-remote-add(1)); a host that already has it keeps it.
The RPM reads its defaults from `/usr/lib64/firefox/browser/defaults/preferences/`, and
Bazzite's `/usr/share/ublue-os/firefox-config/01-bazzite-global.js` reaches only the Flatpak,
which `bazzite-flatpak-manager` copies it into, so the build installs that file there too: the
AI features it turns off (`browser.ml.enable` and the rest) stay off and hardware video
decoding is forced, as in Bazzite; the home page stays Fedora's start page. **gparted** comes
from Fedora, where Bazzite ships `gnome-disk-utility` and gparted only on the live ISO.
**teams-for-linux** is deliberately absent: `flatpak preinstall` synchronises, so removing an
entry later would uninstall the app (flatpak-preinstall(1)).

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
([`gotchas.md`](gotchas.md) § The 1Password app rejects a BrowserSupport whose group id is
below 1000); the build creates them first with fixed gids above 1000, 31001 being NixOS's own
for `onepassword`. The `%post` also makes `chrome-sandbox` setuid root, which Electron's
sandbox requires (https://github.com/electron/electron/issues/17972, cited in the scriptlet),
and the image keeps it: `rpm -V --nomtime 1password` on a host reports its mode, and the mode
and group of the two setgid binaries, as changed.

**The `/opt` payload.** The image's `/opt` is a symlink to `var/opt`, and `/var/opt` is created
on a host by rpm-ostree's own tmpfiles line but does not exist in a build, so an RPM unpacking
under `/opt` dies in cpio. `80-fix-opt.sh` moves every `/var/opt/<name>` to
`/usr/lib/opt/<name>` and writes one tmpfiles `L+` line per directory, so the `/opt/...` paths
baked into the application resolve on the host. bootc keeps `/opt` read-only and links what
must be written into `/var` (bootc.dev, "Filesystem" and "Building images"); the move to
`/usr/lib/opt` is the pattern bazzite-dx uses for an RPM's `/opt` payload
(`bazzite-dx/build_files/50-fix-opt.sh`), rewritten so the checks run before the first move.

Files: `build_files/40-desktop-apps.sh` and `build_files/80-fix-opt.sh` with their tests,
`build_files/lib/flatpak.sh`, `system_files/etc/yum.repos.d/1password.repo`,
`system_files/etc/pki/rpm-gpg/RPM-GPG-KEY-1password`.

## The cleaned stage

The last build script puts back what the build's own transactions changed under `/etc` and
`/usr`, so a host boots an image that carries the features and nothing of the machine that
produced them. Three effects reach a host and belong here.

The accounts created in the build are moved out of `/etc/passwd` and `/etc/group` into
`/usr/lib/passwd` and `/usr/lib/group`, and the `-` backups removed. Their `/etc/shadow` lines
are left where they are: the base ships that file with dozens of entries whose accounts live in
`/usr/lib` already, so the few this stage adds change nothing a host reads. NSS resolves them
through `altfiles`, and `/etc` goes back to `root` and `wheel` alone. Without the move
`bootc container lint --fatal-warnings` refuses the image, its sysusers check reading an
account line in `/etc` as machine state (§ Docker CE for what the boot hook then copies back).
A package's sysusers `m` line on a group of the base, `qemu` in `kvm` and `clevis` in `tss`,
reaches only `/etc/gshadow`, the group's line living in `/usr/lib/group`: the stage carries the
member there, or `qemu:///system` would run QEMU outside `kvm` and away from `/dev/udmabuf`
(`0660 root:kvm`; [`gotchas.md`](gotchas.md) § A sysusers `m` line on a group of the base
reaches only `/etc/gshadow`).

The dnf5 system state under `/usr/lib/sysimage/libdnf5/` is emptied. It is the record of the
build's own transactions (install reasons, repository attribution, the transaction history),
and it would ship to hosts as the history of a machine that no longer exists; rpm-ostree reads
the rpmdb under `/usr/share/rpm`, which stays and is the base's own by hardlink. A host
therefore has no `dnf history` and no install reason for any package, the base's included.
Source: rpm-ostree's rpmdb location (coreos/rpm-ostree#4554, cited in the script).

The vendored repository files are left as they ship, `enabled=0`, and `dnf.conf` is restored
byte for byte: the build enables a repository per transaction and never leaves one enabled
behind it.

Files: `build_files/95-clean-stage.sh` and its test.

## CI: what differs from the family

How a change ships is [`workflow.md`](workflow.md), and the rule behind each choice is
[`conventions.md`](conventions.md). What follows is the delta against Bazzite, bazzite-dx and
aurora.

**A push never publishes.** Bazzite builds, rechunks, tests and pushes in one job gated on the
event (`bazzite/.github/workflows/build.yml`), where aurora takes `publish` as an input
(`aurora/.github/workflows/reusable-build.yml`). This repository is the only one of the family
whose build waits on a lint of its scripts and workflows; aurora runs a just check as a
workflow of its own (`aurora/.github/workflows/validate-just.yml`).

**Fewer actions, more bash.** The family is split on freeing disk: Bazzite and bazzite-dx run
`jlumbroso/free-disk-space` (`bazzite/.github/workflows/build.yml:150`,
`bazzite-dx/.github/workflows/build.yml:67`), Bazzite having dropped
`AdityaGarg8/remove-unwanted-software` in a45a310e and taken `jlumbroso/free-disk-space` in
595c121e; aurora's `stable-f44`, which builds its Fedora 44 images, and image-template pin
`ublue-os/remove-unwanted-software` at `695eb75b`
(`aurora/.github/workflows/reusable-build.yml`,
`image-template/.github/workflows/build.yml:39`), the commit past the apt step whose released
version fails on this runner ([`gotchas.md`](gotchas.md) § `ublue-os/remove-unwanted-software`
v9 fails on `ubuntu-26.04`). No space-freeing action runs here.

Files: `.github/workflows/` and `.github/scripts/`, one owner per script
([`architecture.md`](architecture.md)).
