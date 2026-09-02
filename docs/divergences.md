# Divergences from Bazzite

What this image changes over its base, one entry per feature. A change enters only when
upstream does not cover it, it needs the image layer, a host that runs the image uses it and it
ships a smoke test. Each entry says what the image does, why, where the claim comes from and
which files carry it; the guards themselves live in the build script and its test.
[`gotchas.md`](gotchas.md) holds the surprises this project probed, each with its date.

Contents: three flavours · image identity · signing trust · hook framework · Docker CE · the
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

The base ships no `system-setup.hooks.d` dispatcher. One feature here needs a step that
converges at every boot: the group memberships the container runtime needs.
`ublue-setup-services` comes from the COPR `ublue-os/packages`, the way bazzite-dx installs it
(`bazzite-dx/build_files/20-install-apps.sh`) and enables it
(`bazzite-dx/build_files/40-services.sh`). Only the system unit is enabled here. Our hooks
converge instead of stamping a version. bazzite-dx gates the same work behind libsetup's
`version-script`
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
`qemu-img`, so the QEMU stack enters the image here.

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
(accountsservice, `src/user.c`), keeps `docker` until `sudo gpasswd -d <user> docker`. The
group is allocated dynamically: the `%post` of `docker-ce` runs `groupadd --system`, and the
`uidgid` table of `setup` lacks it, its packaging guidelines giving a fixed number only to ids
shared between machines (Fedora Packaging Guidelines, «Users and Groups»). A host's
`/etc/group` can so keep another number than the image's. The image fixes `docker` at 995, the
number the `bazzite-mx` build gave it, created ahead of the packages from
`/usr/lib/sysusers.d/bazzite-mx-groups.conf`, and the boot hook moves a group of `/etc/group`
on another number to the image's when no other group holds it, the files under `/run`
(`docker.sock`) and `/etc` with the old gid following; the homes and the container stores are
left, their files carrying gids of their own in the same range. The standards of other
distributions fall in Fedora's static range: Gentoo's 48 (`api.gentoo.org/uid-gid.txt`) and
NixOS's 131 (`nixos/modules/misc/ids.nix`), 48 being `apache` in `uidgid`.

Files: `build_files/21-container-runtime.sh` and its test, `build_files/01-system-files.sh`,
`system_files/usr/lib/sysusers.d/bazzite-mx-groups.conf`,
`system_files/etc/yum.repos.d/docker-ce.repo`,
`system_files/etc/pki/rpm-gpg/RPM-GPG-KEY-docker-ce`,
`system_files/usr/lib/modules-load.d/ip_tables.conf`,
`system_files/usr/share/ublue-os/system-setup.hooks.d/10-bazzite-mx-groups.sh`.

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
