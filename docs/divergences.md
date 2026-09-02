# Divergences from Bazzite

What this image changes over its base, one entry per feature. A change enters only when
upstream does not cover it, it needs the image layer, a host that runs the image uses it and it
ships a smoke test. Each entry says what the image does, why, where the claim comes from and
which files carry it; the guards themselves live in the build script and its test.
[`gotchas.md`](gotchas.md) holds the surprises this project probed, each with its date.

Contents: three flavours · image identity · signing trust · hook framework · Docker CE ·
virtualization · VS Code · git tools · command-line tools · mise · desktop applications ·
Sunshine · KDE defaults · MSI laptop · NTFSPLUS · ujust recipes · the cleaned stage · CI.

## Three flavours, one recipe

Bazzite's KDE desktop images come one per graphics stack: `bazzite` for AMD and Intel,
`bazzite-nvidia-open` for the open kernel modules and `bazzite-nvidia` for the closed driver.
This image follows all three, and the base image and the name it maps to are the only
differences between them. A host reaches the changes below only through an image built on its
own stack's base. The recipe therefore stays one file with `BASE_IMAGE` and `IMAGE_NAME` as its
variables, and `resolve-base.sh` maps a flavour to a base image and pins it to a digest. The
closed-driver base carries a kernel of its own, so the kmod-builder stage compiles the
out-of-tree modules against the kernel each base ships. Source: `bazzite`'s
`.github/workflows/build.yml`, the image matrix of the `push-ghcr` job, where the closed-driver
images, `bazzite-nvidia` and its GNOME twin, take the `ogc-lts` kernel.

Every enumeration of the three images is literal: `FLAVOURS` and `image_of` in
`.github/scripts/lib.sh` and the build matrix name them one by one; `resolve-base.sh --digests`
loops over `FLAVOURS`.

Files: `Containerfile`, `.github/scripts/resolve-base.sh`, `.github/scripts/lib.sh`.

## Image identity and the update ref

A layer built on Bazzite keeps Bazzite's identity until something rewrites it, and the identity
is not cosmetic: `image-ref` in `/usr/share/ublue-os/image-info.json` is what Bazzite's shell
greeting (`/usr/share/ublue-os/motd/env.sh`) prints as the host's image and `check-image.sh`
asserts, so an unrewritten file calls the host `ghcr.io/ublue-os/bazzite`. Bazzite's rollback
helper reads `image-name` too: `brh rebase <tag>` builds `ghcr.io/ublue-os/<image-name>:<tag>`,
a repository that does not exist for this image. The image a host pulls from at `bootc upgrade`
is the deployment's origin, which `bootc status` prints. The build writes `image-name`,
`image-vendor`, `image-ref`, `version`, `version-pretty` and `base-version` there,
`base-version` keeping the base's own `version`; `VARIANT_ID` and `IMAGE_ID` in
`/usr/lib/os-release`, the identity os-release(5) gives an image; and `Variant` and `Website`
in `/etc/xdg/kcm-about-distrorc`, the KDE About page, the variant naming the flavour. The OCI
labels are the same identity on the outside, written per build by `image-labels.sh` and
asserted against the pulled image by `check-image.sh`. The inherited
`io.artifacthub.package.readme-url` is restated for the same reason: a label left alone hands
out Bazzite's README as this image's own. Sources: os-release(5), bootc's upgrade contract
(https://bootc-dev.github.io/bootc/), Bazzite's own `image-info.json` and
`/usr/bin/bazzite-rollback-helper`.

Files: `build_files/10-image-info.sh` and its test, `.github/scripts/image-labels.sh`,
`.github/scripts/check-image.sh`.

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

The base ships no `system-setup.hooks.d` dispatcher. Three features here need a step that
converges at every boot or login: the group memberships the container runtime and libvirt need,
the VS Code extensions of each account, and the copy-and-paste skel files of the accounts that
predate the image. `ublue-setup-services` comes from the COPR `ublue-os/packages`, the way
bazzite-dx installs it (`bazzite-dx/build_files/20-install-apps.sh`) and enables it
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
Each moved directory carries the `user.component=<name>` xattr, so the chunker of the main
profile gives it a layer of its own (coreos.github.io/rpm-ostree, "build-chunked-oci",
"Assigning files to specific layers"): the rpmdb names the package's files under `/opt`, and
without the xattr the directory lands in the unpackaged-content layer, which changes at every
release.

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
the hosts are single-user. That premise holds only once the user has set the portal's
credentials. Once enabled, Sunshine listens on every address and its portal admits the LAN
(`bind_address` empty and `origin_web_ui_allowed = lan` by default; LizardByte/Sunshine,
`docs/configuration.md`), the base's `FedoraWorkstation` zone admits TCP and UDP 1025-65535
(`/usr/lib/firewalld/zones/FedoraWorkstation.xml`). So `enable` writes
`origin_web_ui_allowed = pc` to `~/.config/sunshine/sunshine.conf` when the file has no such
key, leaving a value the user set: the portal answers this PC alone, and the stream stays
reachable from the LAN. `/api/password` skips that origin check while no username exists
(LizardByte/Sunshine, `src/confighttp.cpp`: `savePassword` calls `authenticate` only once one
is set), so when `~/.config/sunshine/sunshine_state.json` has no username `enable` asks for the
portal's credentials and writes them with `sunshine --creds` before the service starts, the
password passing through the command line of that one call. It restarts a running Sunshine only
when it wrote one of the two files, which Sunshine reads at start (LizardByte/Sunshine,
`src/httpcommon.cpp`, `src/config.cpp`), so a stream in progress survives an `enable` with
nothing to write. The package's menu entry `Sunshine` (`dev.lizardbyte.app.Sunshine.desktop`)
started the unit with `systemctl start --u`, past both, and its action ran `sunshine` directly:
the build rewrites the entry to run `ujust setup-sunshine enable` in a terminal and drops the
action.

Streaming stays opt-in: the RPM's user unit is disabled for every user with
`systemctl --global disable`, asserted after the install rather than assumed from the presets,
and enabled per user by the recipe. One account at a time per host: https://localhost:47990 is
the portal of the account whose Sunshine started first, and another's cannot bind the ports,
its unit failing after five restarts. Bazzite's announcement telling users of that unit to
reinstall from the Portal is removed, and so is the Portal's Sunshine group, whose `update`,
`uninstall` and `enable-brew` are Bazzite's options. The recipe `setup-sunshine` replaces
Bazzite's with `status`, `enable`, `disable`, `portal` and `virtual-monitor`, the last being
Bazzite's "Virtual Monitor" app rewritten for the RPM. Like Bazzite's, it adds a drop-in that
runs the base's `sunshine-stop-vmon` after every stop of the unit, a restart or a logout
included, which enables every output again and leaves `output_name` empty in `sunshine.conf`,
the Flatpak's under `~/.var/app` first while one is left, which the RPM does not read (the
base's `sunshine-start-vmon` writes there too). For each stream that app's
`sunshine-start-vmon` runs `krfb-virtualmonitor`, a VNC server on port 5905 of every address
with the base's fixed password `sunshinepass` and desktop control on by default (krfb
`rfbserver.cpp`, `krfb.kcfg`), which the zone admits from the LAN while the stream lasts, or
until Sunshine stops when another account holds the base's fixed `/tmp/sunshine-vmon.pid` in
the shared `/tmp`. `systemctl --user revert app-dev.lizardbyte.app.Sunshine.service` removes
the drop-in. `enable` refuses when the unit systemd loads is a copy under the user's home, such
as the one Bazzite's Flatpak leaves in
`~/.config/systemd/user/app-dev.lizardbyte.app.Sunshine.service`, first in the user unit path
and running the Flatpak, and names the remedy:
`flatpak run --command=remove-additional-install.sh dev.lizardbyte.app.Sunshine`, or removing
the file and `systemctl --user daemon-reload`. Not carried over: the install, update and
uninstall paths, the RPM following the image, and the Deck and Homebrew branches, the fleet
having no Deck image. The "Fix Error 503" switch is a KWin permission bypass, and returns as
its own step if a host needs it.

Files: `build_files/41-sunshine.sh` and its test, `build_files/lib/just.sh`,
`system_files/etc/yum.repos.d/sunshine.repo`,
`system_files/etc/pki/rpm-gpg/RPM-GPG-KEY-copr-lizardbyte-stable`,
`system_files/usr/share/ublue-os/just/82-bazzite-sunshine.just`.

## KDE defaults

Four per-user defaults. They reach existing accounts only from the image, two through Plasma's
update scripts and two through a user hook, which is why they are here and not in a recipe.

Two of them are Plasma update scripts under the shell package's `contents/updates/`, the
mechanism Plasma itself and Bazzite use for one-shot per-user defaults: plasmashell runs every
`.js` there once per user and records it in `~/.config/plasmashellrc` (KDE developer
documentation, Plasma scripting), reaching new accounts after the default layout and existing
ones at their next start. An autostart entry with a per-user stamp file would need a wait for
plasmashell on the session bus; this form needs neither. A JavaScript error is only a warning
in the journal, and the script is still marked performed. The CI lint job therefore checks the
files with `node --check`, there being no JavaScript engine in the image. The first sets
`showSeconds=2` on every digital clock that still has the upstream default, leaving a clock the
user set to never alone. The second gives every other screen that has none a bottom panel
copying the primary's geometry and widgets, minus the system tray, a second tray applet
spawning a duplicate containment. A screen that already carries a panel is skipped. A first
login with one screen adds nothing and the script is still marked performed, so
`ujust setup-panels` evaluates the same file through `org.kde.PlasmaShell.evaluateScript`. The
record in `plasmashellrc` is the script's path (plasma-workspace,
`shell/scripting/scriptengine.cpp`, `pendingUpdateScripts`), so an account that already ran a
script, every account that logged in on a published image, never runs a changed version of it,
and a new account runs the current one: `ujust setup-panels` is how an existing account gets a
changed panel script, and the clock script has no recipe.

The other two are skel files for Windows-style copy and paste. Konsole gets `edit_copy` on
`Ctrl+C; Ctrl+Shift+C` through a `sessionui.rc` whose `version="1"` is below Konsole's own, so
KXmlGui merges only its `ActionProperties`; Konsole disables that action while nothing is
selected, so Ctrl+C still interrupts the shell. PowerShell is not in the image, and the skel
profile applies to a pwsh the user installs, binding the two keys through `wl-copy` and
`wl-paste` because PSReadLine's own clipboard functions need xclip on Linux. A skel file is
copied only into the home `useradd` creates (useradd(8), `-k`), so an account that predates the
image would never get either ([`gotchas.md`](gotchas.md) § A skel file reaches no account that
already exists). The user hook `12-bazzite-mx-copy-paste.sh` copies each of the two files at
every login when the account has none, through the same `ublue-user-setup.service` as the VS
Code hook, and leaves a file the user already has alone. A file the user deletes is therefore
copied again at the next login, and one given up is emptied rather than deleted.

Files: `build_files/45-kde-defaults.sh` and its test, the two scripts under
`system_files/usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/`,
`system_files/etc/skel/.local/share/kxmlgui5/konsole/sessionui.rc`,
`system_files/etc/skel/.config/powershell/profile.ps1`,
`system_files/usr/share/ublue-os/user-setup.hooks.d/12-bazzite-mx-copy-paste.sh`, and the
recipe `setup-panels` in `system_files/usr/share/ublue-os/just/95-bazzite-mx.just`.

## MSI laptop: kernel modules and MControlCenter

The fleet's laptop is an MSI machine whose fan curves, shift modes, keyboard backlight and
battery thresholds are reachable only through its embedded controller. Two out-of-tree modules
and a per-host install cover it, and nothing here loads on any other machine. **msi-ec**
(BeardOverflow/msi-ec) is pinned to a commit of `main`. The ogc kernel builds its in-tree copy,
but that copy prints no version and lags the project. Ours lands under `updates/`, which depmod
searches before `kernel/` (kmod's `tools/depmod.c`). The base's copy is signed and carries DMI
aliases, so stock Bazzite loads it at boot on any MSI laptop, Secure Boot on or off; ours has
neither, so here msi-ec loads only through `setup-msi`, and never with Secure Boot on.
**acpi_ec** (saidsay-so/acpi_ec) creates the root-only character device `/dev/ec` that
MControlCenter falls back to for fan speeds when `/sys/kernel/debug/ec/ec0/io` is absent, and
it is absent: the ogc kernel leaves `CONFIG_ACPI_EC_DEBUGFS` unset.

The builder is the base image itself, not an akmods carrier, Bazzite installing `kernel-devel`
for its kernel and versionlocking it. The kernel's build system is called directly rather than
the modules' own `make`, which targets `/lib/modules/$(uname -r)/build`, the runner's kernel
and not the image's. Both modules are unsigned, the kernel setting `CONFIG_MODULE_SIG_ALL=y`
but not `CONFIG_MODULE_SIG_FORCE`. They load with a taint when Secure Boot is off and are
refused when it is on, the IMA architecture policy then enforcing module signatures
(`security/integrity/ima/ima_efi.c`); the recipe prints that reason when modprobe fails. MOK
enrolment is out of scope. Nothing loads them at boot, since every other host never touches
them. `ujust setup-msi enable`, gated on the DMI vendor `Micro-Star`, writes the modules-load
file and loads them now. `verify-host` fails on any other modules-load file naming them. They
stay out of the initramfs by design.

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
design (`fs/ntfs3/Kconfig`: `depends on !NTFS_FS || m`). The 7.2 kernel of `bazzite` and
`bazzite-nvidia-open` builds it as a module, the 6.18 kernel of `bazzite-nvidia` leaves it off
(`CONFIG_NTFS_FS` in `/usr/lib/modules/<kver>/config`). The image builds the author's
standalone packaging of the same code (`namjaejeon/linux-ntfs`) for all three alike, under
`updates/`, which depmod searches before the in-tree `kernel/` (kmod's `tools/depmod.c`),
pinned to a merge commit of `main`: `ntfs-next` is force-pushed and its tip may be mid-rework.
The module is `ntfs.ko` and registers the filesystem type `ntfs`: "ntfsplus" is the project's
name, never the module's nor the mount type's. Its kbuild fragment is gated on
`CONFIG_NTFS_FS`, so `source.env` forces the symbol on the make line
([`gotchas.md`](gotchas.md) § A kbuild fragment gated on a kernel config symbol compiles
nothing and exits 0). Like the MSI modules, `ntfs.ko` is unsigned: the kernel refuses it when
Secure Boot is on, so the opt-in needs Secure Boot off.

The in-kernel `ntfs3` is the fleet's baseline and no fstab row changes NTFS driver without the
host's own choice, so the image ships `blacklist ntfs` in `/usr/lib/modprobe.d/`. That stops
the kernel from loading the driver by alias at the first `mount -t ntfs`, while an explicit
`modprobe ntfs` still works. kmod reads `/etc/modprobe.d` first and skips a later file of the
same name, so a comments-only file of that name under `/etc` masks the blacklist
(modprobe.d(5)). That file is the opt-in: `ujust setup-ntfsplus enable` writes it, `disable`
removes it, and `verify-host` and `migrate` read it. The build also removes the two generic
`mount.ntfs` and `mount.ntfs-fuse` links ntfs-3g installs, under both spellings, `/usr/bin` and
the `/usr/sbin -> bin` symlink ([`gotchas.md`](gotchas.md) § `mount -t ntfs` reaches the kernel
driver only when no `mount.ntfs` helper exists). `mount.ntfs-3g` and `ntfsprogs` stay, so
`mount -t ntfs-3g` remains the explicit FUSE route. Removing the links also moves the volumes
udisks mounts, from the file manager or `udisksctl mount`: Fedora builds udisks2 with
`ntfs_drivers=ntfs,ntfs3` so that its first try reaches ntfs-3g through `mount.ntfs`
(`udisks2.spec`, rhbz#2182206). Without the link that try reaches the kernel: on a host that
did not opt in the blacklist fails it as an unknown type and udisks moves on to `ntfs3`, and
after the opt-in NTFSPLUS takes the volume.

`ujust setup-ntfsplus enable` proves the driver before touching fstab: a loop image formatted
with `mkntfs`, mounted with `-t ntfs` and checked to report `ntfs` as its type, written to,
unmounted, remounted, checksum compared. Only then do the `ntfs3` rows of fstab become `ntfs`,
every `ntfs` row without an `errors=` option gaining `errors=remount-ro` and no mask written,
so a row without `umask`, `fmask` or `dmask` takes what Windows wrote from 0755 under `ntfs3`
to 0777 under NTFSPLUS, writable by every account ([`gotchas.md`](gotchas.md) § The two NTFS
kernel drivers agree on modes and case under a mask, with permissive exceptions). The rewritten
table is verified with `findmnt --verify --tab-file` against the current one before it is
written, an error the current table does not carry refusing it, an unplugged `nofail` volume
counting on both sides ([`gotchas.md`](gotchas.md) § `findmnt --verify` reports an unplugged
`nofail` volume as an error); a rewrite refused or not written on `enable` withdraws the opt-in
this run wrote and unloads the driver, the way every failed step before it does, while an
opt-in from an earlier run stays and the error names `disable`; a backup, `daemon-reload` and a
remount of each rewritten volume follow, a busy volume keeping its mount until the next boot. A
switched row loses the options only `ntfs3` reads (`force`, `prealloc`, `delalloc`), which
NTFSPLUS refuses, and a row left with no option gets `defaults`. `disable` switches the rows
back and takes `errors=remount-ro` out; the dropped options stay out. The probe exists because
a module built for the wrong kernel API dies at its first mount with vermagic and modinfo
green, and fstab mounts fire at boot before the journal is on disk ([`gotchas.md`](gotchas.md)
§ A kernel module can pass vermagic and modinfo and panic at its first use). No mount is ever
proven in the build, there being no kernel to load into, so a pin bump takes the runtime proof
on a booted host. That proof is per kernel series, and no fleet host boots the closed flavour,
whose base carries another series (its `ostree.linux` label): such a host proves it for itself
at opt-in. The opt-in and the `ntfs` rows of fstab follow a rebase unproven, so a move to the
closed flavour takes the order [`migration.md`](migration.md) gives: disable before the rebase,
enable after the reboot. Recovery after a boot panic:
`rpm-ostree rollback && systemctl reboot`, then `ujust setup-ntfsplus disable` on the
deployment that comes up; choosing the previous entry in the boot menu instead repairs its own
`/etc` and leaves the default entry on the broken one, each deployment carrying its own `/etc`
(`rpm-ostree(1)`, `rollback`). The table before the first rewrite is kept at
`/etc/fstab.bazzite-mx-ntfsplus.bak` until `disable` removes it, and
`sudo cp -p /etc/fstab.bazzite-mx-ntfsplus.bak /etc/fstab && sudo systemctl daemon-reload` puts
it back by hand.

NTFSPLUS defaults to `errors=continue`, which disarms its checks at mount: a volume Windows
left dirty, or hibernated with `hiberfil.sys` in its root, would mount read-write without a
warning and a dirty one have its flag cleared at unmount, where `ntfs3` refuses a dirty volume
(`super.c` of `namjaejeon/linux-ntfs` at the commit `source.env` pins, `fs/ntfs3/super.c`). The
`errors=remount-ro` the rewrite adds mounts those two read-only (`Mounting read-only` in the
kernel log); `ntfs3` refuses the option, so `ujust setup-ntfsplus disable` and `ujust migrate`
take it out of a row they rewrite to `ntfs3`, except where a hand-written row carries it as its
only option before dump and pass: that row keeps it and `ntfs3` refuses it. `enable` gives the
option to an `ntfs` row already in fstab too, left by an earlier opt-in or by Bazzite, where
`ntfs` meant ntfs-3g, and leaves an `errors=` value written by hand; under the opt-in
`verify-host` fails an `ntfs` row without an `errors=` option and names `enable` as the remedy.
NTFSPLUS never reads whether `$LogFile` is clean (no `ntfs_is_logfile_clean` at the pin), so
the option does not cover a volume fast startup left with pending log records and no dirty
flag, a data volume being the usual one: it mounts read-write and its `$LogFile` is emptied
(`load_system_files`). Fast startup off in Windows covers it.

A volume udisks mounts, from the file manager or `udisksctl mount`, takes udisks' options,
whose builtin `ntfs:ntfs_defaults` is `uid`, `gid` and `windows_names` and whose
`ntfs:ntfs_allow` has no `errors` (`strings /usr/libexec/udisks2/udisksd`). The image ships
`/etc/udisks2/mount_options.conf` with both keys, each the builtin set plus
`errors=remount-ro`: a key there replaces the builtin set whole, and the defaults must be a
subset of the allowed options (udisks, «Configurable mount options»), which
`tests/55-ntfsplus.sh` compares with the builtin sets. The keys name the `ntfs` driver, so a
volume udisks mounts with `ntfs3` keeps udisks' own options. A volume mounted read-only by the
option says so only in the kernel log; it is writable again after Windows shuts down fully,
fast startup off, and a remount.

Bazzite enables `ntfs-nag.service` for every user, and the image disables it with
`systemctl --global disable`, the way `41-sunshine.sh` disables its own unit. The unit is
`/usr/lib/systemd/user/ntfs-nag.service`, symlinked from
`/etc/systemd/user/xdg-desktop-autostart.target.wants/` in the base. Its script
`/usr/libexec/ntfs-exfat-monitor-script` counts the `ntfs` and `exfat` mounts that already
exist, then reads `findmnt -n --poll -t exfat,ntfs,fuseblk`, which reports only events after
that: the nag never fires for an fstab mount made at boot, and always fires for one that
appears after the graphical session started. An NTFSPLUS volume is type `ntfs`, so on a host
that ran `ujust setup-ntfsplus enable` the base would nag against the feature this image ships.
What a host loses: the `notify-send -u critical` warning that running games from Windows drives
will cause problems, and its link to Bazzite's unsupported-filesystems documentation.

Files: `build_files/55-ntfsplus.sh` and its test, `build_files/kmods/ntfsplus/source.env`,
`system_files/usr/lib/modprobe.d/bazzite-mx-ntfsplus.conf`,
`system_files/etc/udisks2/mount_options.conf`,
`system_files/usr/libexec/bazzite-mx-ntfsplus-setup`, and the recipe `setup-ntfsplus` in
`system_files/usr/share/ublue-os/just/95-bazzite-mx.just`.

## ujust recipes

Bazzite's `ujust` is `just` run on `/usr/share/ublue-os/justfile`, which imports every file
under `/usr/share/ublue-os/just/` by name and sets `allow-duplicate-recipes`. Seven recipes of
ours join it: `setup-panels`, `setup-msi`, `setup-ntfsplus`, `setup-dev`,
`install-jetbrains-toolbox`, `verify-host` and `migrate`.

`95-bazzite-mx.just` is appended as one more `import` line, the way bazzite-dx adds its own
file (`bazzite-dx/build_files/60-clean-base.sh`). With duplicate names across imports the
earlier import wins ([`gotchas.md`](gotchas.md) § `just`: the earlier import wins on a
duplicate recipe name), so an appended import can never override a base recipe. A recipe of
ours that carries an upstream name therefore takes the upstream file's place, as
`84-bazzite-virt.just` and `82-bazzite-sunshine.just` do, each holding exactly the one recipe
we replace. When the upstream file holds other recipes too, the upstream recipe is cut out of
it with its neighbours proven unchanged. `00-prep.sh` records every base recipe file's recipe
set before `system_files` is copied. `70-justfile.sh` then refuses a replaced file whose set
differs from ours, an override whose recipe the base no longer has, and any name defined in two
files.

`verify-host` answers whether a host is where the image expects it. The name is ours, after
Bazzite's `verify-image`, which only rewrites the transport for `ghcr.io/ublue-os`. `migrate`
brings a host to the state this image expects, in one pending deployment, with a confirmation
per mutating step except step 2, which writes the backups, pins the booted deployment and stops
`uupd.timer` unasked, and the reboot left to the user. It uses rpm-ostree rather than
`bootc switch`: rpm-ostree is visible and produces the same origin. What both check and do is
[`migration.md`](migration.md). `setup-dev` runs `mise ls` for status or `mise install` after
seeding the config from `/etc/skel`. `install-jetbrains-toolbox` replaces Bazzite's Homebrew
cask with JetBrains' documented Linux install: read the release feed, download the tarball,
compare its sha256 with the feed's checksum file, unpack and start it once. The build of a
Toolbox already unpacked there is read from the tarball's own `bin/build.txt` (the feed's
`build` field), so a Toolbox of the same build is left alone whoever put it there
([`gotchas.md`](gotchas.md) § A private marker does not identify an installation the recipe did
not make). The Portal still offers JetBrains Toolbox through the Homebrew cask (its
`jetbrains-toolbox-linux` entry); the recipe is the image's route, and using both leaves two
installs.

Files: `build_files/70-justfile.sh` and its test,
`system_files/usr/share/ublue-os/just/95-bazzite-mx.just`, and the helpers
`bazzite-mx-verify-host`, `bazzite-mx-migrate` and `bazzite-mx-jetbrains-toolbox` under
`system_files/usr/libexec/`; the first two source `system_files/usr/lib/bazzite-mx/host.sh`,
which the ntfsplus and MSI helpers share, and the Toolbox helper runs as the user and sources
nothing.

## The cleaned stage

The last build script puts back what the build's own transactions changed under `/etc` and
`/usr`, so a host boots an image that carries the features and nothing of the machine that
produced them. Three effects reach a host and belong here.

The accounts created in the build are moved out of `/etc/passwd` and `/etc/group` into
`/usr/lib/passwd` and `/usr/lib/group`, and the `-` backups removed. Their `/etc/shadow` lines
are left where they are: the base ships that file with dozens of entries whose accounts live in
`/usr/lib` already, so the few this stage adds change nothing a host reads. On the current base
the move is eleven groups and five users, `docker`, `libvirt` and `qemu` among them; NSS
resolves them through `altfiles`, and `/etc` goes back to `root` and `wheel` alone. Without the
move `bootc container lint --fatal-warnings` refuses the image, its sysusers check reading an
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
that proves the signing secret on every push to `main`, and the only one whose build waits on a
lint of its scripts and workflows; aurora runs a just check as a workflow of its own
(`aurora/.github/workflows/validate-just.yml`).

**The artefact that ships is the one that is probed.** Bazzite runs goss on the chunked image
and is the only member of the family that tests what it ships
(`bazzite/.github/workflows/build.yml`). `check-image.sh` does the same with the tools the
image already has, and asserts on the artefact every label `image-labels.sh` wrote.

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
