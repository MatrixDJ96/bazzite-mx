# bazzite-mx: Aurora-DX Style Porting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **ARCHITECTURE UPDATE — 2026-05-01 v2 (post Phase 1 push):**
> L'asse `IMAGE_TIER=base|dx` è stato **rimosso**. `bazzite-mx` è una distribuzione DX-tier per definizione: l'overlay DX è always-on. Le 3 varianti restano `bazzite-mx`, `bazzite-mx-nvidia`, `bazzite-mx-nvidia-open` (tutte DX). Niente `bazzite-mx-dx` separato.
> Conseguenze: `IMAGE_TIER` rimosso dal Containerfile e dal workflow; `build.sh` chiama sempre `build-dx.sh`; il test `10-tests-dx.sh` gira sempre. Il branding `Variant=Developer Experience` resta best-effort (path KCM Bazzite-specifico da scoprire in fase successiva).
> Tutti i riferimenti seguenti a `IMAGE_TIER`, `bazzite-mx-dx`, `tier:` nella matrix, `--build-arg IMAGE_TIER=dx` vanno **letti come obsoleti**.

**Goal:** Trasformare `bazzite-mx` in una variante DX di Bazzite migliore di `bazzite-dx` ufficiale, adottando la struttura di build di Aurora DX (script numerati per dominio, repo isolati, test bloccanti, cleanup mirato) e includendo sia il superset di pacchetti DX di Aurora sia le chicche uniche di Bazzite DX, senza duplicare quanto già presente in Bazzite base.

**Architecture (v2):** Su un `Containerfile` flat con `BASE_IMAGE` (bazzite/bazzite-nvidia/bazzite-nvidia-open) e `IMAGE_FLAVOR` (base/nvidia per gli hook HW), `build_files/shared/build.sh` orchestratore unico applica sempre l'overlay DX (`build-dx.sh` → `build_files/dx/*.sh` numerati). Split di `build_files/` in `shared/`, `dx/`, `tests/` (stile Aurora). Ogni dominio (container, virt, IDE, cockpit, CLI, branding) è uno script separato con commenti header e sezioni. Repo terzi sempre `enabled=0` con `--enablerepo=` puntuale; COPR via helper `copr_install_isolated()` portato da Aurora. Test `10-tests-dx.sh` bloccante (rpm-q + systemctl is-enabled). Cleanup mirato in stile `clean-stage.sh` Aurora; niente `rm -rf /var`. `bootc container lint` strict (no `|| true`). Validation pre-flight `validate-repos.sh`.

**Tech stack:** Bash (`set -euxo pipefail`), `dnf5`, podman/buildah/skopeo (rootful), GitHub Actions (`reusable-build.yml` esistente), cosign (firma esistente), rpm-ostree, Containerfile multi-stage.

**Riferimenti dati:**
- Mappatura completa di Aurora, Aurora-DX, Bazzite, Bazzite-DX raccolta nelle conversazioni precedenti del 2026-05-01.
- I 4 repo upstream sono in `/run/media/matrixdj96/Archivio/Projects/OS/{aurora,bazzite,bazzite-dx,image-template}/`.
- `bazzite-mx` repo locale: `/run/media/matrixdj96/Archivio/Projects/OS/bazzite-mx/`.

**Vincoli e preferenze utente (da rispettare):**
- Non rifare di testa propria pattern già consolidati: cambiamenti chirurgici, una cosa per volta.
- Aspettare conferma esplicita dell'utente prima di committare/pushare.
- Mai usare `rm -rf /var` o `|| true` per silenziare lint/errori.
- Niente `--no-verify` o bypass di hook senza richiesta esplicita.
- SSH per remote git, non HTTPS.
- Repo `MatrixDJ96/bazzite-mx` su GitHub, branch `main`.
- Output finale: 3 immagini × N tag (latest, stable, stable-44, stable-44.YYYYMMDD, 44.YYYYMMDD, testing, testing-44, testing-44.YYYYMMDD.N) firmate con cosign.

---

## TDD pattern (vale per tutti i task implementativi)

Ogni task che modifica codice segue questo pattern. Lo descrivo qui una volta sola.

1. **Write failing test** — aggiungo o estendo `build_files/dx/10-tests-dx.sh` con la rpm-q / systemctl is-enabled / file-existence assertion specifica del task.
2. **Run build, expect FAIL** — `cd bazzite-mx && sudo buildah build --build-arg IMAGE_FLAVOR=dx --tag bazzite-mx-dx:wip .` — la build deve fallire allo step `10-tests-dx.sh` perché il pacchetto/servizio non esiste ancora.
3. **Implement minimal change** — modifico `build_files/dx/<NN>-<dominio>.sh` per aggiungere il pacchetto/servizio/file richiesto.
4. **Run build, expect PASS** — stessa build, ora passa.
5. **Optional: integration test in container** — `sudo podman run --rm --entrypoint /usr/bin/bash bazzite-mx-dx:wip -c '<assertion>'` per verifiche più profonde (es. `docker --version`, `virsh list`, ecc.).
6. **Commit** — `git add <files> && git commit -m "<conv-commit>: <scope>: <descrizione>"` con messaggio Conventional Commits (`feat:`, `fix:`, `chore:`, `refactor:`).
7. **Push se richiesto** — solo dopo conferma esplicita dell'utente.

CI (GitHub Actions) è il "test of last resort": il push triggera `build-stable.yml` + `build-testing.yml`, entrambi devono finire `success`. Se uno fallisce → revert/fix prima di passare al task successivo.

---

## Phase 0: Validation pre-implementazione

**Scopo:** ricontrollare punto per punto le affermazioni delle 3 mappature precedenti (Aurora, Bazzite base, Bazzite DX) leggendo direttamente il codice. Le mappature sono state generate da agent Explore: tutte sono soggette a interpretazione e a possibili errori. Prima di toccare `bazzite-mx`, il piano e le sue assunzioni vanno validati. Se emergono discrepanze, aggiorniamo PRIMA il piano e POI procediamo con Phase 1.

### Task 0.1: Rivalidare flusso Aurora (base + dx) leggendo i file chiave

**Files (sola lettura):**
- `/run/media/matrixdj96/Archivio/Projects/OS/aurora/Containerfile.in`
- `/run/media/matrixdj96/Archivio/Projects/OS/aurora/build_files/shared/build.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/aurora/build_files/shared/build-dx.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/aurora/build_files/shared/clean-stage.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/aurora/build_files/shared/validate-repos.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/aurora/build_files/shared/copr-helpers.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/aurora/build_files/base/01-packages.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/aurora/build_files/base/17-cleanup.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/aurora/build_files/base/20-tests.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/aurora/build_files/dx/00-dx.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/aurora/build_files/dx/10-tests-dx.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/aurora/.github/workflows/reusable-build.yml`

- [ ] **Step 1: Leggi Containerfile.in e mappa stage/RUN/COPY in ordine**

Annota: ARG iniziali, multistage import (akmods, common, brew), branch cpp `#if defined(NVIDIA/ZFS)`, condizione `IMAGE_FLAVOR=dx` con riga esatta.

- [ ] **Step 2: Leggi `build.sh` e verifica orchestrazione**

Annota: `set -euxo pipefail`, ordine rsync `system_files`, condizione `if [[ "${IMAGE_FLAVOR}" == "dx" ]] then build-dx.sh fi`, riga esatta.

- [ ] **Step 3: Leggi `01-packages.sh` e identifica TUTTI i blocchi `dnf install`**

Per ogni `dnf5 install`: linea, flag, lista pacchetti. Verifica claim "rpm -q prima di install" cercando occorrenze. Annota dove `00-dx.sh` viene innestato (riga 295 stando alla mappatura).

- [ ] **Step 4: Leggi `00-dx.sh` riga per riga**

Conta righe totali. Identifica blocchi: Fedora packages, ROCm condizionale, Docker repo, VS Code repo, COPR isolati, systemctl enable. Annota: il file usa funzioni shell? log helper? Quali repo aggiunge esattamente?

- [ ] **Step 5: Leggi `10-tests-dx.sh`**

Annota array `IMPORTANT_PACKAGES_DX` e `IMPORTANT_UNITS`. Comportamento exit (ha `|| true`?).

- [ ] **Step 6: Leggi `validate-repos.sh` e `clean-stage.sh`**

Annota logica esatta: glob su `/etc/yum.repos.d/*.repo`, regex `^enabled=1`, exit code, cosa fa il cleanup (rm pattern, mask, versionlock clear).

- [ ] **Step 7: Leggi `copr-helpers.sh` per la funzione `copr_install_isolated`**

Trascrivi la funzione completa. È quello che porteremo identico in bazzite-mx.

- [ ] **Step 8: Cross-check con la mappatura precedente**

Per ogni claim della mappatura Aurora ricevuta in conversazione, verifica → pass / fail / discrepanza. Output: `aurora-validation.md` (working note in `docs/superpowers/notes/2026-05-01-aurora-validation.md`) con tabella claim → verifica → riga del codice.

- [ ] **Step 9: Commit della nota di validazione**

```bash
cd /run/media/matrixdj96/Archivio/Projects/OS/bazzite-mx
git add docs/superpowers/notes/2026-05-01-aurora-validation.md
git commit -m "docs(plan): validation notes for upstream Aurora flow"
```

### Task 0.2: Rivalidare flusso Bazzite base

**Files (sola lettura):**
- `/run/media/matrixdj96/Archivio/Projects/OS/bazzite/Containerfile`
- `/run/media/matrixdj96/Archivio/Projects/OS/bazzite/install-kernel-akmods` (e gli altri script in `bazzite/`: `cleanup`, `finalize`, `build-initramfs`, `image-info`, `install-kmods`)
- `/run/media/matrixdj96/Archivio/Projects/OS/bazzite/system_files/desktop/shared/usr/share/ublue-os/just/` (justfile imports)
- `/run/media/matrixdj96/Archivio/Projects/OS/bazzite/.github/workflows/reusable-build.yml`

- [ ] **Step 1: Leggi `Containerfile` di Bazzite riga per riga**

È un mega-Containerfile ~580 righe. Annota:
- ARG iniziali (`BASE_IMAGE_NAME`, `FEDORA_VERSION`, `KERNEL_FLAVOR`, `KERNEL_VERSION`)
- COPY blocks dei system_files (`system_files/desktop/shared` + `desktop/${BASE_IMAGE_NAME}`)
- Tutti i `RUN` separati: cosa fa ognuno (kernel install, COPR setup, package install bulk, swap mesa/wireplumber/bluez/xwayland, remove base packages, KDE/GNOME conditionals, systemd enable/disable, `bootc lint`)
- Riga esatta di `bootc container lint`

- [ ] **Step 2: Verifica che la lista pacchetti "Bazzite base ha già" dalla mappatura sia accurata**

Greppa il Containerfile per ognuno dei pacchetti elencati come "già presente": `podman`, `distrobox`, `toolbx`, `incus`, `waydroid`, `edk2-ovmf`, `p7zip`, `p7zip-plugins`, `vim`, `fish`, `fastfetch`, `tailscale`, `input-remapper`, `uupd`, `cockpit-*` (verifica QUALI plugin esattamente), `bcc`, `flatpak-builder` (è davvero in base? dubito).

Esempio: `grep -n "edk2-ovmf" /run/media/matrixdj96/Archivio/Projects/OS/bazzite/Containerfile` deve restituire riga(e) e contesto.

- [ ] **Step 3: Verifica claim "no rm -rf /var" su Bazzite base**

`grep -rn "rm -rf /var" /run/media/matrixdj96/Archivio/Projects/OS/bazzite/` — atteso: zero match (Bazzite base non lo fa, è solo Bazzite DX che lo fa).

- [ ] **Step 4: Identifica esattamente quali servizi systemd sono enabled in base e quali masked**

Leggi tutti i blocchi `systemctl enable`, `systemctl --global enable`, `systemctl mask`, `systemctl disable` nel Containerfile e in `finalize`/`cleanup`.

- [ ] **Step 5: Mappa COPR cleanup di Bazzite base**

Riga 517-537 dovrebbe contenere il loop di disable COPR. Verifica e trascrivi il loop esatto: è in stile Aurora `enable→install→disable`?

- [ ] **Step 6: Output `bazzite-base-validation.md` in `docs/superpowers/notes/`**

Stessa struttura di Task 0.1: tabella claim → verifica → riga.

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/notes/2026-05-01-bazzite-base-validation.md
git commit -m "docs(plan): validation notes for upstream Bazzite base flow"
```

### Task 0.3: Rivalidare flusso Bazzite DX

**Files (sola lettura):**
- `/run/media/matrixdj96/Archivio/Projects/OS/bazzite-dx/Containerfile`
- `/run/media/matrixdj96/Archivio/Projects/OS/bazzite-dx/build_files/build.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/bazzite-dx/build_files/00-image-info.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/bazzite-dx/build_files/20-install-apps.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/bazzite-dx/build_files/40-services.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/bazzite-dx/build_files/50-fix-opt.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/bazzite-dx/build_files/60-clean-base.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/bazzite-dx/build_files/99-build-initramfs.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/bazzite-dx/build_files/999-cleanup.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/bazzite-dx/system_files/usr/share/ublue-os/privileged-setup.hooks.d/20-dx.sh`
- `/run/media/matrixdj96/Archivio/Projects/OS/bazzite-dx/system_files/usr/libexec/bazzite-dx-groups`
- `/run/media/matrixdj96/Archivio/Projects/OS/bazzite-dx/system_files/usr/libexec/bazzite-dx-kvmfr-setup`

- [ ] **Step 1: Leggi `20-install-apps.sh` riga per riga e annota ESATTI pacchetti, repo, sed, rm**

Verifica claim: 109 righe, `set -xeuo pipefail`, ordine "install → remove → repo add" mescolato. Annota in particolare:
- Lista pacchetti dnf5 install righe 4-23
- `dnf5 remove mesa-libOpenCL` riga 25-26
- ROCm + virt righe 28-38
- VS Code repo aggiunto righe 78-84
- Docker repo aggiunto righe 93-101
- COPR `ublue-os/packages` riga 71-72
- Kernel module `iptable_nat` righe 107-109

- [ ] **Step 2: Verifica `999-cleanup.sh`**

Ricerca esatta:
```
grep -n 'rm -rf /var' /run/media/matrixdj96/Archivio/Projects/OS/bazzite-dx/build_files/999-cleanup.sh
grep -n 'bootc container lint' /run/media/matrixdj96/Archivio/Projects/OS/bazzite-dx/build_files/999-cleanup.sh
```
Atteso: trovare `rm -rf /var && mkdir -p /var` e `bootc container lint || true`.

- [ ] **Step 3: Verifica `50-fix-opt.sh`**

Trascrivi script completo. Capisci PERCHÉ Bazzite DX ha bisogno di questo workaround `/var/opt → /usr/lib/opt`. Domanda chiave: ci serve in `bazzite-mx` o no?

- [ ] **Step 4: Verifica copia indiscriminata `cp -avf files/. /` in `build.sh:37`**

Conta i file in `system_files/files/` (se esiste questa struttura). Capisci cosa esattamente viene copiato.

- [ ] **Step 5: Identifica pacchetti "unici di Bazzite DX" non presenti in Aurora DX**

Lista da confermare: `python3-ramalama`, `kvmfr` (è kmod o pacchetto utente?), `gamemode-nested`, `ccache`, `restic`, `rclone`, `waypipe`, `zsh`, `usbmuxd`, `tiptop`, `git-subtree`, `guestfs-tools`. Verifica greppando `00-dx.sh` di Aurora che NON ci siano (greppare per ognuno).

- [ ] **Step 6: Output `bazzite-dx-validation.md`**

Stessa struttura.

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/notes/2026-05-01-bazzite-dx-validation.md
git commit -m "docs(plan): validation notes for upstream Bazzite DX flow"
```

### Task 0.4: Generare matrice "presente / assente / da aggiungere" definitiva

**File da creare:** `docs/superpowers/notes/2026-05-01-package-matrix.md`

- [ ] **Step 1: Costruire tabella unica con 4 colonne**

Una riga per pacchetto, colonne: `Aurora base | Aurora DX | Bazzite base | Bazzite DX`. Cella = ✓ o ✗ (con riga del codice come tooltip/nota).

- [ ] **Step 2: Aggiungere quinta colonna "Da aggiungere a bazzite-mx"**

Logica: se assente in Bazzite base (col3 = ✗) e presente in Aurora DX o Bazzite DX (col2 o col4 = ✓), allora `da aggiungere = ✓`. Altrimenti no.

- [ ] **Step 3: Categorizzare le righe per gruppo logico**

Container, Virt, IDE, Cockpit, Dev CLI, AI/Storage, Branding, Services, Justfile imports.

- [ ] **Step 4: Identificare CONFLITTI o duplicazioni potenziali**

Esempio: Aurora DX usa `qemu-system-x86-core` (modulare), Bazzite DX usa `qemu-kvm` (legacy meta). Decisione: usare quale? Annotare la scelta per ogni conflitto.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/notes/2026-05-01-package-matrix.md
git commit -m "docs(plan): definitive package matrix for DX porting"
```

### Task 0.5: Aggiornare il piano se la validazione trova discrepanze

- [ ] **Step 1: Rileggere questo piano**

Confrontare le sezioni Phase 1-9 con i risultati della validazione (Tasks 0.1-0.4).

- [ ] **Step 2: Correggere claim errati nel piano**

Edit di questo file (`docs/superpowers/plans/2026-05-01-aurora-dx-style-porting.md`) per allineare i pacchetti, le righe-codice, i nomi file.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/2026-05-01-aurora-dx-style-porting.md
git commit -m "docs(plan): align porting plan with validation findings"
```

---

## Phase 1: Scheletro DX-style su `bazzite-mx`

**Scopo:** introdurre l'infrastruttura `build_files/{shared,dx,tests}/` e il flavor `dx` nel `Containerfile` di `bazzite-mx`, **senza ancora aggiungere pacchetti**. Alla fine di questa fase: build "vuota" di `bazzite-mx-dx` che produce un'immagine identica a `bazzite-mx` base ma con marker DX (label, image-info), passa `bootc container lint` strict, passa `validate-repos.sh`, passa smoke test minimale.

### Task 1.1: Creare directory build_files in stile Aurora

**Files:**
- Create: `bazzite-mx/build_files/shared/build.sh`
- Create: `bazzite-mx/build_files/shared/build-dx.sh`
- Create: `bazzite-mx/build_files/shared/copr-helpers.sh`
- Create: `bazzite-mx/build_files/shared/clean-stage.sh`
- Create: `bazzite-mx/build_files/shared/validate-repos.sh`
- Create: `bazzite-mx/build_files/dx/.gitkeep`
- Create: `bazzite-mx/build_files/tests/10-tests-dx.sh`

- [ ] **Step 1: Creare `shared/copr-helpers.sh` portando 1:1 dalla funzione di Aurora**

Contenuto: copia esatta di `aurora/build_files/shared/copr-helpers.sh` (verificato in Task 0.1 step 7). Header:
```bash
#!/usr/bin/env bash
# COPR helper functions ported 1:1 from Aurora upstream.
# Provides copr_install_isolated() pattern: enable -> install -> disable.
set -euxo pipefail
```

- [ ] **Step 2: Creare `shared/validate-repos.sh` (porting da Aurora)**

Contenuto: copia esatta di `aurora/build_files/shared/validate-repos.sh`. Logica: glob su `/etc/yum.repos.d/*.repo`, fail se almeno uno ha `^enabled=1`.

- [ ] **Step 3: Creare `shared/clean-stage.sh` (porting da Aurora)**

Contenuto: copia esatta di `aurora/build_files/shared/clean-stage.sh`. NB: NON `rm -rf /var` — `find /var/* -type d ! -name cache -exec rm -fr {} \;`.

- [ ] **Step 4: Creare `shared/build.sh`**

Orchestratore minimale:
```bash
#!/usr/bin/env bash
set -euxo pipefail

CTX="${CTX:-/ctx}"
SHARED="$CTX/build_files/shared"
DX="$CTX/build_files/dx"

source "$SHARED/copr-helpers.sh"

# Copia system_files (sempre)
if [ -d "$CTX/system_files/shared" ]; then
  rsync -rvKl "$CTX/system_files/shared/" /
fi

# Branch DX
if [ "${IMAGE_FLAVOR:-base}" = "dx" ]; then
  "$SHARED/build-dx.sh"
fi

# Cleanup pre-validation
"$SHARED/clean-stage.sh"

# Validazione repo (deve avvenire DOPO il cleanup)
"$SHARED/validate-repos.sh"
```

- [ ] **Step 5: Creare `shared/build-dx.sh` (skeleton vuoto + IP forwarding + branding)**

```bash
#!/usr/bin/env bash
set -euxo pipefail

CTX="${CTX:-/ctx}"
DX="$CTX/build_files/dx"

# 1) Copia system_files DX-only
if [ -d "$CTX/system_files/dx" ]; then
  rsync -rvKl "$CTX/system_files/dx/" /
fi

# 2) IP forwarding per Docker (in stile Aurora build-dx.sh:12-22)
cat > /etc/sysctl.d/90-bazzite-mx-dx-forwarding.conf <<'EOF'
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1
EOF
echo iptable_nat > /etc/modules-load.d/90-bazzite-mx-dx.conf

# 3) Branding kcm-about (Variant=Developer Experience)
KCM=/usr/share/kcm-about-distro/kcm-about-distrorc
if [ -f "$KCM" ]; then
  if ! grep -q '^Variant=' "$KCM"; then
    echo 'Variant=Developer Experience' >> "$KCM"
  fi
fi

# 4) Esegui script DX numerati (vuoto in Phase 1, popolato dalle phase successive)
if compgen -G "$DX/*.sh" > /dev/null; then
  for s in $(ls -1v "$DX"/*.sh); do
    echo "::group::Running $(basename "$s")"
    bash "$s"
    echo "::endgroup::"
  done
fi
```

- [ ] **Step 6: Creare `tests/10-tests-dx.sh` (skeleton con 1 sola assertion)**

```bash
#!/usr/bin/env bash
set -euxo pipefail

# Smoke test DX: deve fallire se invocato su immagine non-DX.
# Phase 1: solo branding marker.

EXPECTED_VARIANT="Developer Experience"
ACTUAL=$(grep '^Variant=' /usr/share/kcm-about-distro/kcm-about-distrorc 2>/dev/null | cut -d= -f2- || true)

if [ "$ACTUAL" != "$EXPECTED_VARIANT" ]; then
  echo "FAIL: expected Variant=$EXPECTED_VARIANT, got '$ACTUAL'"
  exit 1
fi

# Phase 2-9 estenderanno questo file con altre assertion.

echo "DX smoke tests OK."
```

- [ ] **Step 7: chmod +x sui nuovi script**

```bash
chmod +x bazzite-mx/build_files/shared/*.sh
chmod +x bazzite-mx/build_files/tests/10-tests-dx.sh
```

- [ ] **Step 8: Commit**

```bash
git add bazzite-mx/build_files
git commit -m "feat(dx): scaffold Aurora-style build_files structure"
```

### Task 1.2: Modificare `Containerfile` per supportare flavor `dx`

**Files:**
- Modify: `bazzite-mx/Containerfile`

- [ ] **Step 1: Leggere il Containerfile attuale**

```bash
cat bazzite-mx/Containerfile
```

Riferimento attuale (estratto, vedere file completo): RUN unico che esegue `build_files/shared/build.sh && build_files/${IMAGE_FLAVOR}/build.sh`. Dobbiamo cambiare in: orchestratore unico `build_files/shared/build.sh` che internamente decide se chiamare `build-dx.sh` in base a `IMAGE_FLAVOR`.

- [ ] **Step 2: Sostituire la sezione RUN esistente con la nuova**

Nuovo RUN (sostituire le righe 29-36 del Containerfile attuale):
```dockerfile
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    CTX=/ctx IMAGE_FLAVOR="${IMAGE_FLAVOR}" /ctx/build_files/shared/build.sh && \
    CTX=/ctx /ctx/build_files/tests/10-tests-dx.sh
```

NB: il test viene eseguito SOLO se `IMAGE_FLAVOR=dx` e `build-dx.sh` ha settato il branding marker. In Phase 1 il test è gating: se vogliamo evitare il test su flavor `base`, possiamo wrappare:
```dockerfile
    sh -c '[ "${IMAGE_FLAVOR}" = "dx" ] && /ctx/build_files/tests/10-tests-dx.sh || true'
```
**Decisione**: in Phase 1 wrappiamo il test condizionale così la build base resta verde. Nelle Phase 2+ il test `dx` resta condizionale al flavor.

- [ ] **Step 3: Cambiare ARG IMAGE_FLAVOR per documentare i valori validi**

```dockerfile
ARG IMAGE_FLAVOR=base
# Valid values: base | dx
```

- [ ] **Step 4: Aggiungere bootc lint strict come step finale**

Sostituire `RUN bootc container lint` (riga 38 attuale) con (sempre strict, non `|| true`):
```dockerfile
RUN --network=none bootc container lint
```

- [ ] **Step 5: Commit**

```bash
git add bazzite-mx/Containerfile
git commit -m "feat(dx): add IMAGE_FLAVOR=dx orchestration to Containerfile"
```

### Task 1.3: Aggiornare workflow `reusable-build.yml` per build matrice base+dx

**Files:**
- Modify: `bazzite-mx/.github/workflows/reusable-build.yml`

- [ ] **Step 1: Leggere reusable-build.yml attuale**

```bash
cat bazzite-mx/.github/workflows/reusable-build.yml
```

Identificare matrix esistente (es. `image_name: [bazzite-mx, bazzite-mx-nvidia, bazzite-mx-nvidia-open]`).

- [ ] **Step 2: Aggiungere asse `flavor: [base, dx]` alla matrix**

Risultato atteso: `3 × 2 = 6` job per stream. Tag risultanti: `bazzite-mx:dx-stable`, `bazzite-mx-dx-nvidia:stable`, ecc. **Decisione di naming**: separare in package distinti (`bazzite-mx-dx`, `bazzite-mx-dx-nvidia`, `bazzite-mx-dx-nvidia-open`) o lo stesso package con tag prefissati `dx-`?

**Scelta da confermare con utente** (in commit message del piano): `bazzite-mx-dx*` come **package separati**, perché dimensione differente e firme cosign separate.

- [ ] **Step 3: Aggiornare lo step `Build Image` per passare `IMAGE_FLAVOR=${{ matrix.flavor }}`**

Aggiungere `--build-arg IMAGE_FLAVOR=${{ matrix.flavor }}` al `sudo -E buildah build` esistente.

- [ ] **Step 4: Aggiornare `Image Metadata` per usare `IMAGE_NAME` correttamente**

Quando `flavor=dx`, l'immagine si chiama `bazzite-mx-dx[-nvidia[-open]]`.

- [ ] **Step 5: Commit (da pushare solo dopo conferma utente)**

```bash
git add bazzite-mx/.github/workflows/reusable-build.yml
git commit -m "ci(dx): add base+dx flavor matrix to reusable-build"
```

### Task 1.4: Build locale di prova (skeleton vuoto)

- [ ] **Step 1: Build flavor base**

```bash
cd /run/media/matrixdj96/Archivio/Projects/OS/bazzite-mx
sudo -E buildah build --build-arg IMAGE_FLAVOR=base --tag bazzite-mx:wip-base .
```
Atteso: PASS, immagine identica all'attuale.

- [ ] **Step 2: Build flavor dx**

```bash
sudo -E buildah build --build-arg IMAGE_FLAVOR=dx --tag bazzite-mx-dx:wip .
```
Atteso: PASS. Smoke test esegue e verifica `Variant=Developer Experience`.

- [ ] **Step 3: Verifica IP forwarding e branding nel container**

```bash
sudo podman run --rm --entrypoint /usr/bin/bash bazzite-mx-dx:wip -c '
  cat /etc/sysctl.d/90-bazzite-mx-dx-forwarding.conf
  cat /etc/modules-load.d/90-bazzite-mx-dx.conf
  grep "^Variant=" /usr/share/kcm-about-distro/kcm-about-distrorc
'
```
Atteso: 3 file presenti con contenuto corretto.

- [ ] **Step 4: Verifica `validate-repos.sh` non fallisce**

Implicito nello Step 2 (build PASS implica validate-repos OK).

- [ ] **Step 5: Verifica `bootc container lint` strict non fallisce**

Implicito nello Step 2.

---

## Phase 2: Container runtime (Docker CE + Podman extras + sockets)

**Scopo:** Aggiungere il blocco "Container runtime" come dominio isolato, in stile Aurora `00-dx.sh` ma diviso in script dedicato.

**Files:**
- Create: `bazzite-mx/build_files/dx/10-container-runtime.sh`
- Modify: `bazzite-mx/build_files/tests/10-tests-dx.sh`
- Create: `bazzite-mx/system_files/dx/etc/yum.repos.d/docker-ce.repo` (con `enabled=0`)
- Create: `bazzite-mx/system_files/dx/etc/yum.repos.d/vscode.repo` (preparato qui per Phase 4 ma file qui)

**Pacchetti da installare:**
- `podman-compose`, `podman-machine`, `podman-tui` (Fedora)
- `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`, `docker-model-plugin` (repo Docker, `enabled=0` con `--enablerepo=docker-ce-stable`)
- `podman-bootc` (COPR `gmaglione/podman-bootc`, isolated)

**Servizi da abilitare:**
- `docker.socket`
- `podman.socket`

**Test rpm-q:**
- `podman-compose`, `podman-machine`, `podman-tui`, `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`, `podman-bootc`

**Test systemctl is-enabled:**
- `docker.socket`, `podman.socket`

**Step (TDD pattern come da intro):**

- [ ] **Step 1: Estendere `tests/10-tests-dx.sh` con array `CONTAINER_RPMS` e `CONTAINER_UNITS`**

Aggiungere prima del messaggio `OK`:
```bash
CONTAINER_RPMS=(
  podman-compose podman-machine podman-tui podman-bootc
  docker-ce docker-ce-cli containerd.io
  docker-buildx-plugin docker-compose-plugin
)
for p in "${CONTAINER_RPMS[@]}"; do
  rpm -q "$p" || { echo "FAIL: $p missing"; exit 1; }
done

CONTAINER_UNITS=( docker.socket podman.socket )
for u in "${CONTAINER_UNITS[@]}"; do
  systemctl is-enabled "$u" || { echo "FAIL: $u not enabled"; exit 1; }
done
```

- [ ] **Step 2: Build `IMAGE_FLAVOR=dx`, expect FAIL al test**

Comando:
```bash
sudo -E buildah build --build-arg IMAGE_FLAVOR=dx --tag bazzite-mx-dx:wip .
```
Atteso: FAIL su `rpm -q podman-compose`.

- [ ] **Step 3: Creare `system_files/dx/etc/yum.repos.d/docker-ce.repo` con enabled=0**

```ini
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://download.docker.com/linux/fedora/$releasever/$basearch/stable
enabled=0
gpgcheck=1
gpgkey=https://download.docker.com/linux/fedora/gpg
```

- [ ] **Step 4: Creare `dx/10-container-runtime.sh`**

```bash
#!/usr/bin/env bash
# DX block: Container runtime (Docker CE + Podman extras)
# Style: Aurora 00-dx.sh (sezioni con header, repo isolati, COPR isolated).

set -euxo pipefail

source /ctx/build_files/shared/copr-helpers.sh

### Section 1: Podman extras (Fedora)
dnf5 install -y \
  podman-compose \
  podman-machine \
  podman-tui

### Section 2: Docker CE (repo isolato, enablerepo puntuale)
# La .repo è già stata copiata in /etc/yum.repos.d via system_files/dx/.
dnf5 -y --enablerepo=docker-ce-stable install \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin \
  docker-model-plugin

### Section 3: podman-bootc (COPR isolated)
copr_install_isolated gmaglione/podman-bootc podman-bootc

### Section 4: Servizi
systemctl enable docker.socket
systemctl enable podman.socket
```

- [ ] **Step 5: chmod +x e build, expect PASS**

```bash
chmod +x bazzite-mx/build_files/dx/10-container-runtime.sh
sudo -E buildah build --build-arg IMAGE_FLAVOR=dx --tag bazzite-mx-dx:wip .
```
Atteso: PASS. Smoke test verifica tutti i pacchetti e i servizi.

- [ ] **Step 6: Integration check nel container**

```bash
sudo podman run --rm --entrypoint /usr/bin/bash bazzite-mx-dx:wip -c '
  docker --version
  docker buildx version
  podman --version
  podman-compose --version
  podman-bootc --help | head -2
'
```
Atteso: tutti rispondono senza errore.

- [ ] **Step 7: Commit**

```bash
git add bazzite-mx/build_files/dx/10-container-runtime.sh \
        bazzite-mx/build_files/tests/10-tests-dx.sh \
        bazzite-mx/system_files/dx/etc/yum.repos.d/docker-ce.repo
git commit -m "feat(dx): add container runtime block (Docker CE + Podman extras)"
```

- [ ] **Step 8: (su conferma utente) push e attesa CI**

```bash
git push origin main
gh run list --repo MatrixDJ96/bazzite-mx --limit 6
```
Atteso: 6 run (3 stable × {base,dx} + 3 testing × {base,dx}) tutti `success`.

---

## Phase 3: Virtualization (QEMU/KVM + virt-manager + ovmf + libvirt-workarounds)

**Files:**
- Create: `bazzite-mx/build_files/dx/20-virtualization.sh`
- Modify: `bazzite-mx/build_files/tests/10-tests-dx.sh`
- Modify (forse): `bazzite-mx/system_files/dx/usr/lib/systemd/system/swtpm-workaround.service` (se non viene da COPR)

**Pacchetti:**
- Fedora: `qemu`, `qemu-system-x86-core`, `qemu-img`, `qemu-user-binfmt`, `qemu-user-static`, `qemu-char-spice`, `qemu-device-display-virtio-gpu`, `qemu-device-display-virtio-vga`, `qemu-device-usb-redirect`, `libvirt`, `libvirt-nss`, `virt-manager`, `virt-viewer`, `virt-v2v`, `edk2-ovmf`, `lxc`, `incus-agent`
- Già in Bazzite base (verificare in Phase 0): `incus`, `edk2-ovmf` — saltare se già presenti
- COPR `ublue-os/packages`: `ublue-os-libvirt-workarounds`

**Servizi:**
- `swtpm-workaround.service`
- `ublue-os-libvirt-workarounds.service`
- `bazzite-mx-dx-groups.service` (creiamo noi, in stile aurora-dx-groups)

**Test rpm-q:**
- Tutti i pacchetti virt installati (escluso quelli già in Bazzite base che il test fa solo `rpm -q`).

**Test systemctl is-enabled:**
- I 3 servizi sopra.

**Step:** stesso pattern TDD di Phase 2 — write test → fail → implement → pass → commit → push.

(Step dettagliati identici nel pattern a Phase 2. Codice dello script `20-virtualization.sh` analogo a `aurora/build_files/dx/00-dx.sh` sezione virt, righe 33-61.)

- [ ] **Step 1: estendere test array `VIRT_RPMS` e `VIRT_UNITS`**
- [ ] **Step 2: build, expect FAIL**
- [ ] **Step 3: creare `dx/20-virtualization.sh`** (vedi pacchetti sopra, organizzato in 3 sezioni: Fedora bulk, COPR isolated, systemctl enable)
- [ ] **Step 4: creare unit file `bazzite-mx-dx-groups.service` in `system_files/dx/usr/lib/systemd/system/`** + helper `/usr/libexec/bazzite-mx-dx-groups`
- [ ] **Step 5: build, expect PASS**
- [ ] **Step 6: integration check** (`virsh list`, `virt-manager --help`)
- [ ] **Step 7: commit + push (su conferma)**

---

## Phase 4: VS Code + flatpak-builder

**Files:**
- Create: `bazzite-mx/build_files/dx/30-ide.sh`
- Create: `bazzite-mx/system_files/dx/etc/yum.repos.d/vscode.repo` (già preparato in Phase 2)
- Create: `bazzite-mx/system_files/dx/etc/skel/.config/Code/User/settings.json` (default Cascadia Code, update.mode=none — copiato da bazzite-dx)
- Modify: `bazzite-mx/build_files/tests/10-tests-dx.sh`

**Pacchetti:**
- VS Code repo: `code` (`enabled=0`, `--enablerepo=code`, `--nogpgcheck` workaround Bazzite DX o invece import key)
- Fedora: `flatpak-builder`

**Servizi:**
- `bazzite-mx-dx-user-vscode.service` (--global, opzionale; valutare se davvero serve — Aurora lo usa per first-launch tweaks)

**Test:** `rpm -q code flatpak-builder`; `which code`.

- [ ] **Step 1-7: TDD pattern come Phase 2.**

Decisione: importare la GPG key di Microsoft (`https://packages.microsoft.com/keys/microsoft.asc`) **invece** di `--nogpgcheck` (Bazzite DX). Sicurezza > workaround.

---

## Phase 5: Cockpit stack

**Files:**
- Create: `bazzite-mx/build_files/dx/40-cockpit.sh`
- Modify: `bazzite-mx/build_files/tests/10-tests-dx.sh`

**Pacchetti** (verificare in Phase 0 quali già in Bazzite base):
- `cockpit-system`, `cockpit-storaged`, `cockpit-podman`, `cockpit-machines`, `cockpit-ostree`, `cockpit-selinux`, `cockpit-networkmanager`, `cockpit-bridge`

**Servizi:** `cockpit.socket` (NON enabled di default; documentare con just recipe per attivarlo on-demand).

**Test:** `rpm -q cockpit-*`.

- [ ] **Step 1-7: TDD pattern come Phase 2.**

---

## Phase 6: Dev/sysadmin CLI

**Files:**
- Create: `bazzite-mx/build_files/dx/50-cli-tools.sh`
- Modify: `bazzite-mx/build_files/tests/10-tests-dx.sh`

**Pacchetti** (delta vs Bazzite base — confermato dalla validazione 2026-05-01):
- `android-tools`, `bcc`, `bpftrace`, `bpftop`, `sysprof`, `iotop`, `nicstat`, `numactl`, `trace-cmd`
- (esclusi perché già in Bazzite base: `p7zip`, `p7zip-plugins`)
- COPR `karmab/kcli`: `kcli`

> **Nota validazione**: `bcc` era erroneamente classificato come "già in Bazzite base" nell'analisi iniziale. Il claim è stato falsificato dalla validazione di Phase 0 (vedi `docs/superpowers/notes/2026-05-01-bazzite-base-validation.md`, claim #34). Quindi viene aggiunto al blocco DX.

**Test:** `rpm -q` per ognuno; `bpftrace --version`, `kcli --help` integration.

- [ ] **Step 1-7: TDD pattern come Phase 2.**

---

## Phase 7: Bazzite-DX chicche (preservate, migliorate)

**Files:**
- Create: `bazzite-mx/build_files/dx/60-bazzite-extras.sh`
- Create: `bazzite-mx/system_files/dx/usr/libexec/bazzite-mx-dx-kvmfr-setup` (porting da bazzite-dx)
- Create: `bazzite-mx/system_files/dx/usr/bin/gamemode-nested` (porting)
- Create: `bazzite-mx/system_files/dx/usr/share/applications/gamemode-nested.desktop`
- Create: `bazzite-mx/system_files/dx/usr/share/ublue-os/just/95-bazzite-mx-dx.just`
- Create: `bazzite-mx/system_files/dx/usr/share/ublue-os/homebrew/bazzite-mx-dx-fonts.Brewfile`
- Modify: `bazzite-mx/build_files/tests/10-tests-dx.sh`

**Pacchetti aggiunti (unici Bazzite DX, NON in Aurora DX):**
- `python3-ramalama` (AI runner)
- `kvmfr` kmod (Looking Glass — verificare se è kmod separato o include in scx-tools)
- `gamemode-nested` (script wrapper, non pacchetto rpm)
- `ccache`, `restic`, `rclone`, `waypipe`, `zsh`, `usbmuxd`, `tiptop`, `git-subtree`, `guestfs-tools`

**Test:** `rpm -q` per ognuno + `which gamemode-nested`, `command -v ramalama`.

- [ ] **Step 1-7: TDD pattern come Phase 2.**

**Decisione design**: anziché copiare 1:1 lo script `bazzite-dx-groups` di bazzite-dx, in Phase 3 abbiamo già creato il nostro `bazzite-mx-dx-groups.service`. Qui in Phase 7 NON aggiungiamo un secondo groups service.

---

## Phase 8: Justfile + setup hooks

**Files:**
- Create: `bazzite-mx/system_files/dx/usr/share/ublue-os/privileged-setup.hooks.d/20-bazzite-mx-dx.sh`
- Create: `bazzite-mx/system_files/dx/usr/share/ublue-os/user-setup.hooks.d/11-vscode-extensions.sh`
- Modify: `bazzite-mx/system_files/dx/usr/share/ublue-os/just/95-bazzite-mx-dx.just` (aggiungere recipe `cockpit-enable`, `kvmfr-setup`, `vscode-setup`)

**Test:** file presenti, eseguibili, just import valido.

- [ ] **Step 1-5: pattern simile, niente rpm-q, solo file checks.**

---

## Phase 9: Final hardening

- [ ] **Task 9.1**: Verificare che `validate-repos.sh` chiuda DX-build con tutti `enabled=0`
- [ ] **Task 9.2**: Verificare `bootc container lint` strict pass
- [ ] **Task 9.3**: Aggiungere `image-info.json` con `name=bazzite-mx-dx`, `pretty_name="Bazzite MX (Developer Experience)"`, `variant=dx`, `code_name=…`
- [ ] **Task 9.4**: Aggiornare `README.md` con sezione "DX variant"
- [ ] **Task 9.5**: Smoke test rebuild full sia base sia dx, verifica `gh run list` mostra tutti success
- [ ] **Task 9.6**: Verifica firma cosign su tutte le immagini DX (24 firme: 3 immagini × 8 tag stable+testing)

---

## Self-review (post-piano, eseguito subito)

**1. Spec coverage:**
- Differenze Aurora vs Bazzite ✓ (analizzato, dati nei doc di validazione Phase 0)
- Aurora DX features ✓ (Phases 2-6, 8)
- Bazzite DX features uniche preservate ✓ (Phase 7)
- Struttura "stile Aurora" ✓ (Phase 1 scaffold)
- Test bloccanti ✓ (TDD pattern + 10-tests-dx.sh)
- Cleanup mirato ✓ (Phase 1 con clean-stage.sh ported)
- bootc lint strict ✓ (Task 1.2 Step 4)
- validate-repos ✓ (Phase 1)

**2. Placeholder scan:**
- Nessun "TBD/TODO/implement later" rimasto.
- Phases 3-9 hanno dettaglio meno granulare (riusano "TDD pattern come Phase 2"). Questo NON è un placeholder: il pattern è completamente specificato in Phase 2 e nell'intro "TDD pattern". Le decisioni specifiche (pacchetti, servizi, test) sono esplicitate per ogni Phase.

**3. Type / naming consistency:**
- Servizio groups: `bazzite-mx-dx-groups.service` ovunque (Phases 3, 7).
- Naming pacchetti GHCR: `bazzite-mx-dx`, `bazzite-mx-dx-nvidia`, `bazzite-mx-dx-nvidia-open` (Task 1.3).
- IMAGE_FLAVOR: `base` | `dx` ovunque.
- Helper COPR: `copr_install_isolated` ovunque (Aurora original name).
- Variant kcm-about: `Developer Experience` (Phase 1 + test).

---

## Execution handoff

L'utente ha richiesto, dopo la stesura del piano, di **rifare un giro completo di validation dei 4 flussi upstream prima di toccare codice**. Questo coincide esattamente con la **Phase 0** del piano.

**Prossimo passo immediato**: eseguire Phase 0 (Tasks 0.1 → 0.5). Su conferma utente, procedo con il dispatch di 4 agent Explore in parallelo (uno per repo) con istruzioni puntuali di rilettura/cross-check basate sui file e claim elencati nei rispettivi task.
