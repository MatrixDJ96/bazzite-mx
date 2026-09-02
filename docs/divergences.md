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
