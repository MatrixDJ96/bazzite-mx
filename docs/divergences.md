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
