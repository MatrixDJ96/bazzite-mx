# Bazzite base flow — validation against earlier analysis

**Repo**: `/run/media/matrixdj96/Archivio/Projects/OS/bazzite`
**Date**: 2026-05-01

## Summary

| Claims tested | ✓ verified | ⚠ partial | ✗ falsified |
|---|---|---|---|
| 45 | 41 | 1 | 3 |

**3 falsificazioni rilevate**, 1 di esse impatta il piano di porting (claim #34: bcc).

## Validation table

| # | Claim | File | Riga | Risultato | Note |
|---|---|---|---|---|---|
| 1 | Containerfile flat (no `.in`) | Containerfile | — | ✓ | confermato |
| 2 | Containerfile ~580 righe | Containerfile | EOF | ✗ | **829 righe**, non ~580 |
| 3 | `ARG BASE_IMAGE_NAME=kinoite` | Containerfile | 30 | ✓ | esatto |
| 4 | `ARG FEDORA_VERSION=44` | Containerfile | 31 | ✓ | esatto |
| 5 | `ARG KERNEL_FLAVOR=ogc`, `KERNEL_VERSION=6.19.11-ogc1.1.fc44.x86_64` | Containerfile | 36-37 | ✓ | esatto |
| 6 | Nessun `build.sh` orchestratore root | — | — | ✓ | confermato |
| 7 | Script standalone in `build_files/`: `install-kernel-akmods`, `install-kmods`, `cleanup`, `finalize`, `build-initramfs`, `image-info`, `ghcurl`, `build-gnome-extensions` | build_files/ | — | ✓ | tutti presenti |
| 8 | install-kernel-akmods `set -eoux pipefail` | build_files/install-kernel-akmods | 3 | ✓ | esatto |
| 9 | cleanup `set -eoux pipefail` | build_files/cleanup | 3 | ✓ | esatto |
| 10 | cleanup ~8 righe | build_files/cleanup | EOF | ✓ | 8 righe |
| 11 | finalize ~43 righe, passwd/group consolidation | build_files/finalize | 12-32, EOF | ✓ | 43 righe esatte |
| 12 | build-initramfs ~16 righe, dracut | build_files/build-initramfs | 5-15, EOF | ✓ | 16 righe esatte |
| 13 | 6+ COPR: ublue-os/{bazzite,bazzite-multilib,staging,packages}, ycollet/audinux, che/nerd-fonts | Containerfile | 105-110 | ✓ | tutti presenti |
| 14 | COPR bieszczaders/kernel-cachyos-addons | Containerfile | 207 | ✓ | enable riga 207 |
| 15 | Pattern COPR enable→install→DISABLE | Containerfile | 105-115, 530-537 | ✓ | enable loop 105-115, disable loop 530-537 |
| 16 | Terra repo enable/disable | Containerfile | 116, 122 | ✓ | esatto |
| 17 | Kernel custom non-Fedora | build_files/install-kernel-akmods | — | ⚠ | nome esatto del pacchetto kernel non visibile nel Containerfile (è nei tmp rpm) |
| 18 | 14 kmods elencati | build_files/install-kernel-akmods | 35-50 | ✓ | tutti presenti |
| 19 | Gaming: steam, lutris, winetricks, terra-gamescope, umu-launcher, vkBasalt, mangohud, obs-vkcapture, openxr | Containerfile | 314-342 | ✓ | tutti presenti |
| 20 | Mesa swap | Containerfile | 143 | ✓ | `terra-mesa` toswap |
| 21 | Wireplumber/Bluez/Xwayland swap da COPR | Containerfile | 141-142 | ✓ | esatto |
| 22 | podman | Containerfile | 271, 560 | ✓ | cockpit-podman + podman.socket |
| 23 | distrobox | Containerfile | 572 | ✓ | distrobox.ini |
| 24 | toolbx | Containerfile | 572 | ✓ | esatto |
| 25 | incus | Containerfile | 554, 574 | ✓ | incus-workaround.service + incus.ini |
| 26 | waydroid | Containerfile | 285, 562 | ✓ | install + disable service |
| 27 | edk2-ovmf | Containerfile | 281 | ✓ | esatto |
| 28 | p7zip, p7zip-plugins | Containerfile | 260-261 | ✓ | entrambi presenti |
| 29 | vim, fish, fastfetch, btop, duf, glow, gum | Containerfile | 248-269 | ✓ | tutti 7 presenti |
| 30 | tailscale (disabled) | Containerfile | 246, 556 | ✓ | install + disable tailscaled.service |
| 31 | input-remapper | Containerfile | 233, 550 | ✓ | install + enable service |
| 32 | uupd + uupd.timer | Containerfile | 283, 553 | ✓ | esatto |
| 33 | cockpit-* (esatto: 6 plugin) | Containerfile | 270-275 | ✓ | networkmanager, podman, selinux, system, files, storaged |
| 34 | bcc | Containerfile | — | ✗ | **bcc NON presente in Bazzite base** — va installato in DX |
| 35 | bpftrace/bpftop/sysprof/iotop/nicstat/numactl/trace-cmd assenti | Containerfile | — | ✓ | confermato assenti (li installeremo in DX) |
| 36 | flatpak-builder assente | Containerfile | — | ✓ | confermato assente |
| 37 | qemu/libvirt/virt-manager assenti | Containerfile | — | ✓ | confermato assenti |
| 38 | docker-ce assente | Containerfile | — | ✓ | confermato assente |
| 39 | code/VS Code assente | Containerfile | — | ✓ | confermato assente |
| 40 | ROCm assente | Containerfile | — | ✓ | confermato assente |
| 41 | Enabled: brew-setup, input-remapper, bazzite-flatpak-manager, uupd.timer, bazzite-hardware-setup, greenboot-healthcheck | Containerfile | 547-563 | ✓ | tutti enabled |
| 42 | --global enable: bazzite-user-setup, podman.socket | Containerfile | 559-560 | ✓ | esatto |
| 43 | Disabled/masked: iwd, iscsi, rpm-ostreed-automatic.timer, tailscaled, waydroid-container | Containerfile | 292-294, 552, 556, 562 | ✓ | esatto |
| 44 | `bootc container lint` strict (no `\|\| true`) | Containerfile | 582, 759, 829 | ✓ | 3 chiamate, tutte strict |
| 45 | Nessun test smoke script | tests/ | — | ✗ | **esiste** `tests/dgoss/tests.d/00-smoke/test.sh` |

## Falsificazioni

### Impatto sul piano

1. **Claim #34 — bcc NON è in Bazzite base**.
   **Conseguenza per il piano**: Phase 6 (Dev/sysadmin CLI) deve installare anche `bcc` esplicitamente. Aggiornamento richiesto al piano.

### Senza impatto

2. **Claim #2 — Containerfile è 829 righe, non ~580**. Era una stima errata, non blocca nulla. Il file rimane comunque "monolitico" come affermato nello stile Aurora vs Bazzite.
3. **Claim #45 — Esiste un test smoke (`tests/dgoss/`) in Bazzite base**. Interessante: dgoss è infrastruttura di goss tests usata in CI Bazzite. Non viene eseguita durante il container build (è separata). Per il piano bazzite-mx continuiamo a creare il nostro `10-tests-dx.sh` interno alla build (più semplice, blocca direttamente la build se fallisce, in linea con stile Aurora).

## Implicazioni per il piano

**Modifica richiesta**: aggiornare Phase 6 in `2026-05-01-aurora-dx-style-porting.md` per aggiungere `bcc` alla lista pacchetti del blocco CLI.
