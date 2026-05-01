# Package matrix — Aurora vs Aurora DX vs Bazzite vs Bazzite DX

**Date**: 2026-05-01
**Source**: validazioni `2026-05-01-{aurora,bazzite-base,bazzite-dx}-validation.md`.
**Purpose**: tabella unica per decidere QUALI pacchetti aggiungere a `bazzite-mx` nel layer DX, evitando duplicazioni con quanto già presente in Bazzite base.

## Legenda

- **A**: presente in Aurora base
- **A-DX**: presente in Aurora DX (overlay base)
- **B**: presente in Bazzite base
- **B-DX**: presente in Bazzite DX (overlay base)
- **Action**: cosa fa il piano `2026-05-01-aurora-dx-style-porting.md`
  - `SKIP` → non serve
  - `BASE` → già presente in Bazzite base, NON installare nel DX
  - `Phase N` → installare nel blocco N del layer DX di bazzite-mx
- **(c)** = condizionale (es. ROCm su non-nvidia)

## Container runtime

| Pacchetto | A | A-DX | B | B-DX | Action |
|---|:-:|:-:|:-:|:-:|---|
| podman | ✓ | ✓ | ✓ | ✓ | BASE |
| distrobox | ✓ | ✓ | ✓ | ✓ | BASE |
| toolbx | — | — | ✓ | ✓ | BASE |
| podman-compose | — | ✓ | — | — | Phase 2 |
| podman-machine | — | ✓ | — | ✓ | Phase 2 |
| podman-tui | — | ✓ | — | ✓ | Phase 2 |
| podman-bootc | — | ✓ (COPR) | — | — | Phase 2 (COPR isolato) |
| docker-ce | — | ✓ | — | ✓ | Phase 2 |
| docker-ce-cli | — | ✓ | — | ✓ | Phase 2 |
| containerd.io | — | ✓ | — | ✓ | Phase 2 |
| docker-buildx-plugin | — | ✓ | — | ✓ | Phase 2 |
| docker-compose-plugin | — | ✓ | — | ✓ | Phase 2 |
| docker-model-plugin | — | ✓ | — | — | Phase 2 (in più rispetto a Bazzite DX) |

## Virtualization (QEMU/KVM/libvirt)

| Pacchetto | A | A-DX | B | B-DX | Action |
|---|:-:|:-:|:-:|:-:|---|
| qemu | — | ✓ | — | ✓ | Phase 3 |
| qemu-system-x86-core | — | ✓ | — | — | Phase 3 (modulare, in stile Aurora) |
| qemu-img | — | ✓ | — | — | Phase 3 |
| qemu-user-binfmt | — | ✓ | — | — | Phase 3 |
| qemu-user-static | — | ✓ | — | — | Phase 3 |
| qemu-char-spice | — | ✓ | — | — | Phase 3 |
| qemu-device-display-virtio-gpu | — | ✓ | — | — | Phase 3 |
| qemu-device-display-virtio-vga | — | ✓ | — | — | Phase 3 |
| qemu-device-usb-redirect | — | ✓ | — | — | Phase 3 |
| qemu-kvm | — | — | — | ✓ | SKIP (preferiamo modulari Aurora) |
| libvirt | — | ✓ | — | ✓ | Phase 3 |
| libvirt-nss | — | ✓ | — | — | Phase 3 |
| virt-manager | — | ✓ | — | ✓ | Phase 3 |
| virt-viewer | — | ✓ | — | — | Phase 3 |
| virt-v2v | — | ✓ | — | — | Phase 3 |
| edk2-ovmf | — | ✓ | ✓ | ✓ | BASE (già presente) |
| lxc | — | ✓ | — | — | Phase 3 |
| incus | ✓? | ✓ | ✓ | — | BASE |
| incus-agent | — | ✓ | — | — | Phase 3 |
| guestfs-tools | — | — | — | ✓ | Phase 3 (chicca da Bazzite DX) |

## ROCm (condizionale: skip se IMAGE_NAME =~ nvidia)

| Pacchetto | A | A-DX | B | B-DX | Action |
|---|:-:|:-:|:-:|:-:|---|
| rocm-hip | — | ✓ (c) | — | ✓ | Phase 3 (c) |
| rocm-opencl | — | ✓ (c) | — | ✓ | Phase 3 (c) |
| rocm-smi | — | ✓ (c) | — | ✓ | Phase 3 (c) |
| rocm-clinfo | — | — | — | ✓ | Phase 3 (c) — chicca Bazzite DX |

## IDE & build

| Pacchetto | A | A-DX | B | B-DX | Action |
|---|:-:|:-:|:-:|:-:|---|
| code (VS Code) | — | ✓ | — | ✓ | Phase 4 |
| flatpak-builder | — | ✓ | — | ✓ | Phase 4 |

## Cockpit stack (DX-grade)

| Pacchetto | A | A-DX | B | B-DX | Action |
|---|:-:|:-:|:-:|:-:|---|
| cockpit-system | — | ✓ | ✓ | — | BASE |
| cockpit-storaged | — | ✓ | ✓ | — | BASE |
| cockpit-podman | — | ✓ | ✓ | — | BASE |
| cockpit-selinux | — | ✓ | ✓ | — | BASE |
| cockpit-networkmanager | — | ✓ | ✓ | — | BASE |
| cockpit-files | — | — | ✓ | — | BASE |
| cockpit-machines | — | ✓ | — | — | Phase 5 |
| cockpit-ostree | — | ✓ | — | — | Phase 5 |
| cockpit-bridge | — | ✓ | — | — | Phase 5 |

## Dev/sysadmin CLI

| Pacchetto | A | A-DX | B | B-DX | Action |
|---|:-:|:-:|:-:|:-:|---|
| android-tools | — | ✓ | — | ✓ | Phase 6 |
| bcc | — | ✓ | ✗ | ✓ | Phase 6 (validazione: NON in B base) |
| bpftrace | — | ✓ | — | ✓ | Phase 6 |
| bpftop | — | ✓ | — | ✓ | Phase 6 |
| sysprof | — | ✓ | — | ✓ | Phase 6 |
| iotop | — | ✓ | — | — | Phase 6 |
| nicstat | — | ✓ | — | ✓ | Phase 6 |
| numactl | — | ✓ | — | ✓ | Phase 6 |
| trace-cmd | — | ✓ | — | — | Phase 6 |
| p7zip | — | ✓ | ✓ | — | BASE |
| p7zip-plugins | — | ✓ | ✓ | — | BASE |
| kcli | — | ✓ (COPR) | — | — | Phase 6 (COPR isolato) |
| ublue-os-libvirt-workarounds | — | ✓ (COPR) | — | — | Phase 3 (COPR isolato, fa parte virt) |

## Bazzite DX chicche (Phase 7)

| Pacchetto | A | A-DX | B | B-DX | Action |
|---|:-:|:-:|:-:|:-:|---|
| python3-ramalama | — | — | — | ✓ | Phase 7 |
| ccache | — | — | — | ✓ | Phase 7 |
| restic | — | — | — | ✓ | Phase 7 |
| rclone | — | — | — | ✓ | Phase 7 |
| waypipe | — | — | — | ✓ | Phase 7 |
| zsh | ✓ | ✓ | — | ✓ | Phase 7 |
| usbmuxd | — | — | — | ✓ | Phase 7 |
| tiptop | — | — | — | ✓ | Phase 7 |
| git-subtree | — | — | — | ✓ | Phase 7 |
| guestfs-tools | — | — | — | ✓ | Phase 3 (è virt-related) |
| ublue-setup-services | — | — | — | ✓ (COPR) | Phase 7 (COPR isolato) |

## Servizi systemd

| Servizio | A | A-DX | B | B-DX | Action |
|---|:-:|:-:|:-:|:-:|---|
| docker.socket | — | ✓ | — | ✓ | Phase 2 |
| podman.socket | — | ✓ | — | ✓ | Phase 2 |
| swtpm-workaround.service | — | ✓ | — | — | Phase 3 |
| ublue-os-libvirt-workarounds.service | — | ✓ | — | — | Phase 3 |
| `aurora-dx-groups.service` / `bazzite-mx-dx-groups.service` | — | ✓ | — | ✓ (b-dx) | Phase 3 (creiamo nostro) |
| `aurora-dx-user-vscode.service` (--global) | — | ✓ | — | — | Phase 4 (decidere se replicare) |
| podman.socket (già in B base via --global) | ✓ | ✓ | ✓ | ✓ | BASE |
| input-remapper.service | ✓ | ✓ | ✓ | ✓ | BASE |
| uupd.timer | ✓ | ✓ | ✓ | ✓ | BASE |
| bazzite-flatpak-manager.service | — | — | ✓ | — | BASE |
| bazzite-hardware-setup.service | — | — | ✓ | — | BASE |
| greenboot-healthcheck.service | — | — | ✓ | — | BASE |

## Repo terzi

| Repo | A | A-DX | B | B-DX | Action |
|---|:-:|:-:|:-:|:-:|---|
| Docker CE (Microsoft) | — | ✓ enabled=0 | — | ✓ enabled=0 | Phase 2 (enabled=0 + `--enablerepo=docker-ce-stable`) |
| VS Code (Microsoft) | — | ✓ enabled=0 | — | ✓ enabled=0 | Phase 4 (enabled=0 + GPG key import, no `--nogpgcheck`) |
| terra-* | — | — | ✓ | — | BASE (già configurato in Bazzite) |
| ublue-os/* (COPR) | parziale | parziale | ✓ | ✓ | BASE (gestito da Bazzite base) |
| copr:gmaglione/podman-bootc | — | ✓ isolated | — | — | Phase 2 (helper) |
| copr:karmab/kcli | — | ✓ isolated | — | — | Phase 6 (helper) |
| copr:ublue-os/packages (libvirt-workarounds) | — | ✓ isolated | — | — | Phase 3 (helper) |

## Pattern strutturali

| Aspetto | A | A-DX | B | B-DX | Adottiamo? |
|---|:-:|:-:|:-:|:-:|---|
| Containerfile templato (`.in` con cpp) | ✓ | ✓ | — | — | NO (overhead inutile, basta `Containerfile` flat) |
| `build_files/shared/build.sh` orchestratore | ✓ | ✓ | — | ✓ | SÌ — Phase 1.1 |
| Split `shared/` + `dx/` + `tests/` | ✓ | ✓ | — | — | SÌ — Phase 1.1 |
| `copr_install_isolated()` helper | ✓ | ✓ | — | — | SÌ — Phase 1.1 (port 1:1) |
| `validate-repos.sh` pre-validation | ✓ | ✓ | — | — | SÌ — Phase 1.1 |
| `clean-stage.sh` cleanup mirato (no `rm -rf /var`) | ✓ | ✓ | parziale | — | SÌ — Phase 1.1 (port 1:1) |
| `10-tests-dx.sh` smoke bloccante | — | ✓ | — | — | SÌ — Phase 1.1 e estensioni |
| `bootc container lint` strict | ✓ | ✓ | ✓ | — | SÌ — Phase 1.2 |
| Branding `Variant=Developer Experience` | — | ✓ | — | — | SÌ — Phase 1.1 |
| IP forwarding sysctl per Docker | — | ✓ | — | (inline mod_load) | SÌ — Phase 1.1 |
| `iptable_nat` modules-load.d | — | implicito | — | ✓ | SÌ — Phase 1.1 |
| 50-fix-opt.sh (workaround `/var/opt`) | — | — | — | ✓ | DA VALUTARE in Phase 0/Task 0.3 step 3 |
| 99-build-initramfs.sh (dracut rebuild) | — | — | — | ✓ | NO (Bazzite base lo fa già) |
| `cp -avf files/. /` indiscriminato | — | — | — | ✓ | NO (preferiamo `rsync -rvKl system_files/dx/` separato) |

## Sintesi falsificazioni dalla validazione

| # | Falsificazione | Impatto |
|---|---|---|
| Bazzite base #34 | `bcc` NON è in Bazzite base | **Phase 6 aggiornata** (aggiunto `bcc`) |
| Bazzite base #2 | Containerfile è 829 righe, non ~580 | Nessuno |
| Bazzite base #45 | Esiste `tests/dgoss/` smoke | Nessuno (continuiamo con `10-tests-dx.sh` interno) |
| Bazzite DX #3 | Typo upstream `{IMAGE_VENDOR:-…}` | Nessuno (non importiamo) |
| Bazzite DX #6 | `build.sh` usa `set -eo pipefail` non `-euxo` | Nessuno (noi usiamo `-euxo` in stile Aurora) |
| Aurora #7 | `set -eoux` invece di `-euxo` | Nessuno (semantica identica) |

## Decisioni chiave

1. **Naming pacchetti GHCR**: package separati `bazzite-mx-dx`, `bazzite-mx-dx-nvidia`, `bazzite-mx-dx-nvidia-open` (vedi Task 1.3 step 2 del piano).
2. **Modulare vs meta**: usiamo i pacchetti QEMU **modulari** di Aurora (`qemu-system-x86-core`, ecc.), NON `qemu-kvm` legacy.
3. **VS Code**: importiamo la GPG key Microsoft invece di `--nogpgcheck` (anti-pattern di Bazzite DX).
4. **`/var/opt` fix**: valutare in Task 0.3 step 3 della validazione (resta da fare). Se Bazzite base ha già il fix → SKIP. Se no → riportiamo `50-fix-opt.sh` adattato.
5. **Initramfs rebuild**: NON lo replichiamo (Bazzite base lo gestisce già).

## Numeri finali

- Pacchetti `BASE` (già in Bazzite, salviamo): **15+**
- Pacchetti **da installare** in Phase 2-7: **~50**
- COPR helper isolati: **3** (podman-bootc, kcli, ublue-os-libvirt-workarounds)
- Repo terzi `enabled=0`: **2** (Docker, VS Code)
- Servizi nuovi da abilitare: **5** (docker.socket, podman.socket, swtpm-workaround, libvirt-workarounds, bazzite-mx-dx-groups)
