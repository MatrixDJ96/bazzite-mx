# Bazzite DX flow — validation against earlier analysis

**Repo**: `/run/media/matrixdj96/Archivio/Projects/OS/bazzite-dx`
**Date**: 2026-05-01

## Summary

| Claims tested | ✓ verified | ⚠ partial | ✗ falsified |
|---|---|---|---|
| 47 | 44 | 3 | 0 |

Tutti i claim strutturali confermati. Discrepanze sono minori e non impattano il piano di porting.

## Validation table

| # | Claim | File | Riga | Risultato | Note |
|---|---|---|---|---|---|
| 1 | Containerfile flat ~16 righe | Containerfile | 1-16 | ✓ | esatto |
| 2 | ARG BASE_IMAGE, IMAGE_NAME=bazzite-dx, IMAGE_VENDOR=ublue-os | Containerfile | 1, 10, 11 | ⚠ | vedi #3 |
| 3 | Typo `{IMAGE_VENDOR:-ublue-os}` manca `$` | Containerfile | 11 | ✓ confermato | Bug upstream — non impatta il porting |
| 4 | UN SOLO RUN con mount + build.sh | Containerfile | 13-16 | ✓ | esatto |
| 5 | Nessun branch DE nel Containerfile | Containerfile | 1-16 | ✓ | layer puro |
| 6 | build.sh `set -euxo pipefail` (varianti) | build_files/build.sh | 3 | ⚠ | usa `set -eo pipefail` (più permissivo) |
| 7 | Esporta CONTEXT_PATH, SCRIPTS_PATH, MAJOR_VERSION_NUMBER | build_files/build.sh | 5-11 | ✓ | esatto |
| 8 | `find ... \| sort --sort=human-numeric` | build_files/build.sh | 19 | ✓ | `--zero-terminated --sort=human-numeric` |
| 9 | `cp -avf $CONTEXT_PATH/files/. /` | build_files/build.sh | 37 | ✓ | esatto |
| 10 | Script numerati: 00, 20, 40, 50, 60, 99, 999 | build_files/ | — | ✓ | 7 file presenti |
| 11 | 00-image-info.sh ~24 righe, sed su 4 file | 00-image-info.sh | 1-25 | ✓ | 25 righe |
| 12 | 20-install-apps.sh ~109 righe MONOLITICO | 20-install-apps.sh | 1-109 | ✓ | confermato, no funzioni |
| 13 | 40-services.sh ~8 righe, 5 systemctl enable | 40-services.sh | 1-9 | ✓ | docker.socket, podman.socket, ublue-system-setup, ublue-user-setup (--global), bazzite-dx-groups |
| 14 | 50-fix-opt.sh ~20 righe, /var/opt → /usr/lib/opt | 50-fix-opt.sh | 1-21 | ✓ | esatto |
| 15 | 60-clean-base.sh ~5 righe, justfile import | 60-clean-base.sh | 1-6 | ✓ | esatto |
| 16 | 99-build-initramfs.sh ~25 righe, dracut | 99-build-initramfs.sh | 1-26 | ✓ | esatto |
| 17 | 999-cleanup.sh ~26 righe | 999-cleanup.sh | 1-27 | ✓ | 27 righe |
| 18 | 999: `dnf5 clean all` | 999-cleanup.sh | 13 | ✓ | esatto |
| 19 | 999: `rm -rf /var && mkdir -p /var` (DISTRUTTIVO) | 999-cleanup.sh | 20-21 | ✓ | testualmente esatto |
| 20 | 999: `bootc container lint \|\| true` (PERMISSIVO) | 999-cleanup.sh | 24 | ✓ | testualmente esatto |
| 21 | 20-install-apps.sh `set -xeuo pipefail` | 20-install-apps.sh | 2 | ✓ | esatto |
| 22 | dnf5 install: 19 pacchetti (android-tools…zsh) | 20-install-apps.sh | 4-23 | ✓ | tutti presenti |
| 23 | `dnf5 remove -y mesa-libOpenCL` | 20-install-apps.sh | 25-26 | ✓ | esatto |
| 24 | dnf5 install weak-deps=False: 10 pacchetti virt+rocm | 20-install-apps.sh | 28-38 | ✓ | esatto |
| 25 | KDE/GNOME branching inline (40-68) | 20-install-apps.sh | 40-68 | ✓ | nessuno script separato |
| 26 | `--enable-repo="copr:..."` per ublue-setup-services | 20-install-apps.sh | 71-72 | ✓ | esatto |
| 27 | VS Code repo + `gpgcheck=0` + `--nogpgcheck` | 20-install-apps.sh | 78-84 | ✓ | esatto |
| 28 | Docker repo + `--enable-repo=docker-ce-stable` + fallback F42 | 20-install-apps.sh | 93-101 | ✓ | esatto |
| 29 | Docker pkgs: 5 (no docker-model-plugin) | 20-install-apps.sh | 86-92 | ✓ | esatto |
| 30 | NON include docker-model-plugin | 20-install-apps.sh | 86-92 | ✓ | confermato assenza |
| 31 | Manca podman-compose, podman-bootc | 20-install-apps.sh | 4-38 | ✓ | confermato assenza |
| 32 | Manca Cockpit stack | 20-install-apps.sh | 1-109 | ✓ | confermato assenza |
| 33 | Manca lxc, incus, virt-viewer, virt-v2v, swtpm, kcli | 20-install-apps.sh | 1-109 | ✓ | confermato assenza |
| 34 | iptable_nat preload | 20-install-apps.sh | 107-109 | ✓ | esatto |
| 35 | vscode `enabled=0` | 20-install-apps.sh | 79 | ✓ | esatto |
| 36 | docker-ce-stable `enabled=0` | 20-install-apps.sh | 94 | ✓ | esatto |
| 37 | NESSUN cleanup repo dopo install | 20-install-apps.sh | 78-101 | ✓ | nessun `rm -f` di .repo |
| 38 | system_files/usr/libexec/bazzite-dx-groups | system_files/ | — | ✓ | trovato |
| 39 | system_files/usr/libexec/bazzite-dx-kvmfr-setup ~127 righe | system_files/ | — | ⚠ | 126 righe (off-by-one) |
| 40 | bazzite-dx-groups.service Type=oneshot | system_files/ | — | ✓ | esatto |
| 41 | 95-bazzite-dx.just | system_files/ | — | ✓ | trovato |
| 42 | 84-bazzite-virt.just | system_files/ | — | ✓ | trovato |
| 43 | Setup hooks: 20-dx.sh, 11-vscode-extensions.sh | system_files/ | — | ✓ | trovati |
| 44 | VSCode default settings | system_files/ | — | ✓ | trovato |
| 45 | system_flatpaks ~40 app | system_files/ | — | ✓ | 42 righe, 40 app |
| 46 | bazzite-dx-fonts.Brewfile | system_files/ | — | ✓ | trovato |
| 47 | Nessun test script | build_files/ | — | ✓ | confermato assenza |

## Discrepanze trovate

### Minori (non impattano il piano)

1. **Bug upstream**: `Containerfile:11` ha `{IMAGE_VENDOR:-ublue-os}` invece di `${IMAGE_VENDOR:-ublue-os}`. Non importeremo questo file in `bazzite-mx` quindi non c'è da correggere.
2. **`build.sh:3`** usa `set -eo pipefail` (no `-u`, no `-x`). Rispetto al claim "varianti di `set -euxo`" è più debole ma comunque "una variante". Il nostro `bazzite-mx/build_files/shared/build.sh` userà `set -euxo pipefail` (in stile Aurora, NON in stile Bazzite DX).
3. **kvmfr-setup**: 126 righe non 127. Off-by-one nel claim.

### Falsificazioni

Nessuna.

## Implicazioni per il piano

Tutti i claim su Bazzite DX sono confermati nelle parti rilevanti per il porting. Il piano `2026-05-01-aurora-dx-style-porting.md` non richiede modifiche.

**Anti-pattern confermati che NON replichiamo in `bazzite-mx`**:
- `rm -rf /var` distruttivo (999-cleanup.sh:20-21)
- `bootc container lint \|\| true` permissivo (999-cleanup.sh:24)
- 20-install-apps.sh monolitico (109 righe, mix install/repo/sysctl/sed)
- Repo VS Code/Docker orfani (mai puliti)
- Nessun test smoke script
- `cp -avf files/. /` indiscriminato (no split per flavor)
