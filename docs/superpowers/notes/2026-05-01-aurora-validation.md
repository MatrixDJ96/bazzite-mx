# Aurora flow — validation against earlier analysis

**Repo**: `/run/media/matrixdj96/Archivio/Projects/OS/aurora`
**Date**: 2026-05-01
**Method**: agent-driven re-read of upstream source files vs. claims from initial analysis.

## Summary

| Claims tested | ✓ verified | ⚠ partial | ✗ falsified |
|---|---|---|---|
| 33 | 32 | 1 | 0 |

Nessun claim è stato falsificato. La struttura e l'implementazione del flavor DX di Aurora corrispondono accuratamente all'analisi iniziale.

## Validation table

| # | Claim | File | Riga | Risultato | Note |
|---|---|---|---|---|---|
| 1 | `Containerfile.in` con cpp `#if defined(NVIDIA/ZFS)` | Containerfile.in | 17, 21 | ✓ | 4 varianti definite (17, 21, 94, 112) |
| 2 | `ARG BASE_IMAGE_NAME=kinoite` | Containerfile.in | 2 | ✓ | `${BASE_IMAGE_NAME}:-kinoite` |
| 3 | `ARG FEDORA_MAJOR_VERSION=43` | Containerfile.in | 4 | ✓ | `${FEDORA_MAJOR_VERSION}:-43` |
| 4 | 4 varianti cpp | Containerfile.in | 17, 21, 94, 112 | ✓ | NVIDIA, ZFS, NVIDIA&!ZFS, NVIDIA&ZFS |
| 5 | Stage `ctx` righe 25-37 | Containerfile.in | 25-37 | ✓ | `FROM scratch AS ctx` |
| 6 | `IMAGE_FLAVOR=dx` in build.sh:20-22 | build_files/shared/build.sh | 20-21 | ✓ | `if [[ "${IMAGE_FLAVOR}" == "dx" ]]; then build-dx.sh; fi` |
| 6b | `IMAGE_FLAVOR=dx` in 01-packages.sh:295-297 | build_files/base/01-packages.sh | 295-296 | ✓ | richiama `00-dx.sh` |
| 7 | build.sh `set -euxo pipefail` | build_files/shared/build.sh | 3 | ⚠ | flag order `eoux` (semantica identica) |
| 8 | rsync `system_files/shared/` → `/` | build_files/shared/build.sh | 18 | ✓ | `rsync -rvKl /ctx/system_files/shared/ /` |
| 9 | build-dx.sh: rsync dx, sysctl, branding | build_files/shared/build-dx.sh | 8, 13, 25 | ✓ | tutti presenti |
| 10 | `copr_install_isolated()` in copr-helpers.sh | build_files/shared/copr-helpers.sh | 4-23 | ✓ | 47 righe totali |
| 11 | clean-stage.sh ~25 righe, NO `rm -rf /var` | build_files/shared/clean-stage.sh | 17 | ✓ | usa `find /var/* -maxdepth 0 -type d ! -name cache -exec rm -fr {} \;` |
| 12 | validate-repos.sh ~121 righe, fail su `enabled=1` | build_files/shared/validate-repos.sh | 30, 53-62, 77-88 | ✓ | 121 righe esatte |
| 13 | 01-packages.sh 299 righe | build_files/base/01-packages.sh | EOF | ✓ | esatto |
| 13b | 01-packages.sh:295-297 chiama 00-dx.sh | build_files/base/01-packages.sh | 295-296 | ✓ | conferma |
| 14 | sezioni con commenti header | build_files/base/01-packages.sh | 46-52 | ✓ | NOTE/Packages |
| 15 | `rpm -qa --queryformat` per excluded | build_files/base/01-packages.sh | 245-252 | ✓ | esatto |
| 16 | 17-cleanup.sh disable repo loop | build_files/base/17-cleanup.sh | 53-88 | ✓ | multimedia(53), terra(65), copr(72), rpmfusion(79) |
| 17 | 20-tests.sh test bloccanti | build_files/base/20-tests.sh | 102-104, 138-141, 173-178 | ✓ | exit 1 senza fallback |
| 18 | 00-dx.sh sezionato | build_files/dx/00-dx.sh | 7-136 | ✓ | tutti i blocchi presenti |
| 19 | Docker repo `addrepo` + `enabled=0` | build_files/dx/00-dx.sh | 77-78 | ✓ | esatto |
| 20 | VSCode repo `tee` + `enabled=0` | build_files/dx/00-dx.sh | 89, 97 | ✓ | esatto |
| 21 | ROCm condizionale `! IMAGE_NAME =~ nvidia` | build_files/dx/00-dx.sh | 69-74 | ✓ | esatto |
| 22 | `copr_install_isolated` per kcli/podman-bootc/libvirt-workarounds | build_files/dx/00-dx.sh | 104-106 | ✓ | esatto |
| 23 | systemctl enable di 6 servizi DX | build_files/dx/00-dx.sh | 130-136 | ✓ | docker.socket, podman.socket, swtpm-workaround, libvirt-workarounds, aurora-dx-groups, aurora-dx-user-vscode (--global) |
| 24 | 10-tests-dx.sh array + exit 1 | build_files/dx/10-tests-dx.sh | 7-32 | ✓ | bloccante |
| 25 | Cockpit stack 8 plugin | build_files/dx/00-dx.sh | 23-30 | ✓ | tutti presenti |
| 26 | QEMU full stack 9 pacchetti | build_files/dx/00-dx.sh | 47-55 | ✓ | tutti presenti |
| 27 | Virt tools 9 pacchetti | build_files/dx/00-dx.sh | 31, 36-38, 59-61 | ✓ | tutti presenti |
| 28 | Docker stack 6 pacchetti | build_files/dx/00-dx.sh | 79-85 | ✓ | tutti presenti |
| 29 | VSCode pacchetto singolo `code` | build_files/dx/00-dx.sh | 99 | ✓ | esatto |
| 30 | Dev CLI 12 pacchetti | build_files/dx/00-dx.sh | 19-22, 32, 35, 39-40, 42-43 | ✓ | tutti presenti |
| 31 | ROCm 3 pacchetti | build_files/dx/00-dx.sh | 70-73 | ✓ | esatto |
| 32 | COPR 3 (kcli, podman-bootc, libvirt-workarounds) | build_files/dx/00-dx.sh | 104-106 | ✓ | esatto |
| 33 | Workflow matrix con flavor (`brand-name`, `brand-name-dx`) | .github/workflows/reusable-build.yml | 45-48 | ✓ | matrix corretta |

## Discrepanze trovate

### Minori (non impattano il piano)

- **Claim #7**: flag order `eoux` invece di `euxo`. Identità semantica garantita, nessun fix necessario.
- **Claim #16**: tolleranza ±3 righe rispetto al claim originale (53-83 → 53-88), tutti gli elementi presenti.

### Falsificazioni

Nessuna.

## Implicazioni per il piano

Il piano `2026-05-01-aurora-dx-style-porting.md` può procedere così com'è per quanto riguarda i claim su Aurora. **Nessun aggiornamento necessario** sulla base di questa validazione.
