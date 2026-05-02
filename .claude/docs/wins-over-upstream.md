# Wins over `bazzite-dx` upstream

bazzite-mx is a personal fork that aims to be **strictly better** than
`ublue-os/bazzite-dx` upstream by adopting Aurora-DX's build patterns and
fixing concrete issues. Cumulative wins as of 2026-05-02: **15 wins**.

## 1. Strict repo isolation via `validate-repos.sh`

**Upstream**: no equivalent. bazzite-dx ships its image and trusts that
the install order leaves no third-party repo enabled.

**Us**: `build_files/shared/validate-repos.sh` runs at the end of every
build. Hard-fails if any file in the explicit `OTHER_REPOS` list (or any
`_copr:*` / `_copr_*` / `rpmfusion-*`) has `^enabled=1`. Plus an
informational catch-all sweep that lists every other `.repo` file so a
new third-party landing without registration is visible in PR review.

**Why it matters**: a deployed `bootc upgrade` on the user's machine
re-reads `/etc/yum.repos.d/`. A leftover `enabled=1` on docker-ce.repo
would silently pull docker package updates from docker.com on every
upgrade, breaking the reproducibility we promise.

## 2. `docker-ce.repo` vendored in git

**Upstream**: `dnf5 config-manager addrepo --from-repofile=https://download.docker.com/...`
fetched at build time, every time. No auditable diff in git if Docker
upstream changes the .repo file format / baseurl / gpgkey.

**Us**: `system_files/etc/yum.repos.d/docker-ce.repo` committed (commit
`650f002`). Single section `[docker-ce]` with `enabled=0`, `gpgcheck=1`,
`gpgkey=https://download.docker.com/linux/fedora/gpg`. Any future
upstream change requires a deliberate edit of the vendored file in a PR.

**Why it matters**: supply-chain auditability. Reviewer of a future PR
can see exactly what the trust anchor for Docker installs is, without
diffing against external state.

## 3. `swtpm` always installed

**Upstream**: bazzite-dx uses `dnf5 --setopt=install_weak_deps=False
install` for the virt block. This skips `swtpm` because it's only
recommended (not required) by libvirt.

**Us**: explicit `swtpm swtpm-tools` in `build_files/dx/20-virtualization.sh`
(commit `906abd7`).

**Why it matters**: Windows 11 VMs require a TPM 2.0 to install. Without
swtpm on the host, `virt-manager` cannot create a working Windows 11 VM —
the user gets a confusing "this PC doesn't meet the requirements" wall.
Anyone testing Windows compat in a libvirt VM (i.e., most DX users) needs
swtpm. Bazzite-DX users currently have to layer it post-install.

## 4. VSCode `gpgcheck=1`

**Upstream**: bazzite-dx's install pattern sets `gpgcheck=0` on the vscode
repo with a `FIXME: gpgcheck broken on newer rpm policies` comment.

**Us**: `system_files/etc/yum.repos.d/vscode.repo` ships `gpgcheck=1`.
Verified empirically on Bazzite 44.20260501 / dnf5 5.x that the Microsoft
.asc key (0xBE1229CF, fingerprint
BC528686B50D79E339D3721CEB3E94ADBE1229CF) imports cleanly during the
first transaction touching the repo (commit `5e88c35`).

**Why it matters**: actual signature verification of the `code` package
on every install. The bazzite-dx FIXME comment was true for an earlier
dnf/rpm version; it has aged out. We catch the fix.

## 5. Single-flavour MX architecture

**Upstream**: bazzite-dx is a separate "DX-tier" image alongside
`bazzite-base`. Users have to choose which package to track and switching
requires `bootc switch`.

**Us**: bazzite-mx is the **only** flavour. The original plan had an
`IMAGE_TIER=base|dx` axis; collapsed early in the session (commit
`98dcba3`). Three GHCR images differ only in `BASE_IMAGE` (`bazzite`,
`bazzite-nvidia`, `bazzite-nvidia-open`) — picked by hardware, not by
"do I want DX features".

**Why it matters**: simpler mental model, simpler build matrix (3 jobs ×
2 streams instead of 6 × 2), no cognitive overhead of "am I on the right
flavour?". Trade-off: image size larger, ~15 GB. Acceptable for a personal
build.

## 6. `bazzite-mx-groups.service` for first-boot UX

**Upstream**: bazzite-dx-groups exists, but Bazzite base does not have
the equivalent — and bazzite-dx bundles its groups setup with several
other concerns. We split it cleanly.

**Us**: `system_files/usr/lib/systemd/system/bazzite-mx-groups.service`
+ `/usr/libexec/bazzite-mx-groups`. Oneshot at first boot adds wheel
users to `docker` and `libvirt` groups. Versioned via
`/etc/bazzite-mx/groups-version` so a script update re-runs (commit
`906abd7`, hardened in `3200764`).

**Why it matters**: without this, Phase 2's `docker.socket` is enabled
but the user can't `docker ps` without `sudo`. Phase 3's libvirt is
similarly inaccessible. UX regression that bazzite-dx upstream has
fixed but Bazzite base does not.

## 7. Phase 4 split: editor vs Git GUI

**Upstream**: bazzite-dx and Aurora-DX both bundle vscode + a few git
helpers (and gitkraken nowhere) under one big install script.

**Us**: `30-ide.sh` is editor-only (vscode); `35-git-tools.sh` is
GitKraken + `git-credential-libsecret`. Semantically separate
domains in separate scripts (commit `5a0dd78`). And we add
`git-credential-libsecret` (Aurora base only, missing from Bazzite
base AND bazzite-dx) for keyring-backed git auth.

**Why it matters**: clearer file-to-domain mapping; easier to add a
future "Git tools" item (e.g., `lazygit`) without bloating the IDE
script. `git-credential-libsecret` upgrades the day-1 git auth UX
on Bazzite for free.

## 8. VSCode `update.mode=none` atomic-correct default

**Upstream**: bazzite-dx ships the same setting plus opinionated font
(Cascadia Code) + theme defaults. AmyOS goes further with formatOnSave +
Hack Nerd Font + zsh terminal default + many style choices.

**Us**: `system_files/etc/skel/.config/Code/User/settings.json` is just
`{ "update.mode": "none" }`. The atomic-correctness fix only — no font,
no theme, no formatter opinion (commit `5a0dd78`).

**Why it matters**: distros should not impose stylistic preferences. The
fix is mandatory (VSCode's self-updater fights a read-only /usr); the
rest is the user's choice. Minimalism is a feature.

## 9. `bcc-tools` shipped alongside `bcc`

**Upstream**: both Aurora-DX (`build_files/dx/00-dx.sh:20`) and
bazzite-dx (`build_files/20-install-apps.sh:6`) install only `bcc`,
which is the BPF Compiler Collection **library** + Python bindings.
The actual command-line tracing utilities (`execsnoop`, `opensnoop`,
`tcpconnect`, `biotop`, `runqlat`, etc.) live in `bcc-tools`, a
separate ~2 MiB package that neither distro installs.

**Us**: `build_files/dx/40-dev-cli.sh` installs both `bcc` and
`bcc-tools` (commit `d7dc9c2`). The tools land under
`/usr/share/bcc/tools/<name>`.

**Why it matters**: a user typing `dnf install bcc` and then asking
"where's `execsnoop`?" gets answered out of the box on bazzite-mx.
On Aurora-DX or bazzite-dx, they have to layer `bcc-tools`
post-install. The 2 MiB cost is negligible for the UX gain.

## 10. `gh` from upstream vendored repo

**Upstream**: bazzite-dx does not install gh at all. Aurora's CLI list
(if it includes gh, which it doesn't appear to) would use Fedora's
package, currently at `gh-2.87.3-1.fc44`.

**Us**: vendored `system_files/etc/yum.repos.d/gh-cli.repo` pointing
at GitHub's official `https://cli.github.com/packages/rpm` with
`enabled=0`, `gpgcheck=1` against the upstream
`githubcli-archive-keyring.asc` (commit `d7dc9c2`). At install time
we use `dnf5 -y --enablerepo=gh-cli install gh`. The repo gives us
`gh-2.92.0` (released 2026-04-28) — multiple minor versions ahead
of the Fedora repo.

**Why it matters**: `gh` evolves quickly (new commands, GitHub API
features). Lagging by 5+ versions on a "DX" distro is a poor signal.
The vendoring pattern matches what we did for docker-ce.

## 11. More complete `ublue-setup-services` adoption

**Upstream**: bazzite-dx is the only adopter of `ublue-setup-services`
across the wider ublue ecosystem (Aurora, Aurora-DX, AmyOS, Bazzite
base do not use it as of 2026-05-02). And even bazzite-dx uses the
framework only partially:
- VSCode extensions hook (`/usr/share/ublue-os/user-setup.hooks.d/11-vscode-extensions.sh`) — uses `libsetup.sh` ✓
- Privileged-setup hook (`/usr/share/ublue-os/privileged-setup.hooks.d/20-dx.sh`) — uses `libsetup.sh` ✓
- `bazzite-dx-groups` — **does NOT use libsetup.sh**, keeps a custom
  versioning file at `/etc/ublue/dx-groups`.

**Us**: every setup-time script in bazzite-mx uses the framework
(commit `40611b1`). `bazzite-mx-groups` was migrated from a
custom systemd service + custom version file to a system-setup hook
at `/usr/share/ublue-os/system-setup.hooks.d/10-bazzite-mx-groups.sh`,
sourcing `libsetup.sh` and calling `version-script bazzite-mx-groups
system 1`. All versioning state is now centralized in one JSON file
(`/var/roothome/.local/share/ublue/setup_versioning.json`).

**Why it matters**: Phase 8 will add more setup hooks (vscode
extensions, tailscale init, etc.). Mixing two versioning patterns
(custom file + JSON) would be confusing and harder to debug. Going
all-in on the framework now means every future hook follows the same
pattern.

## 12. Firefox dal repo RPM ufficiale Mozilla

**Upstream**: bazzite-dx, Bazzite base e tutto il ublue ecosystem
(Aurora, Aurora-DX, AmyOS) shippano Firefox solo come flatpak
Flathub `org.mozilla.firefox` (lista default-install di Bazzite).

**Us**: `system_files/etc/yum.repos.d/mozilla.repo` vendoredato
(`enabled=0`, `priority=10`, `gpgcheck=1`, `repo_gpgcheck=0` per Mozilla
docs). `build_files/dx/45-firefox-rpm.sh` rimuove eventuale `firefox`
del repo Fedora se presente (gate via `rpm -q`) e installa
`firefox` + `firefox-l10n-it` da repo Mozilla (commit `5d17d01`,
fix-forward review in `b71b0e1`). Smoke test asserisce
`VENDOR=Mozilla` come guard contro regressione al pacchetto Fedora.

**Why it matters**: 1Password native messaging socket (browser autofill)
è bloccato dal sandbox del flatpak. La rpm Mozilla risolve out-of-the-box.
Bonus: niente flatpak-runtime drift dalle system libs (glibc/mesa/...).

## 13. Migration cleanup hooks per flatpak preesistente

**Upstream**: nessuna distro ublue gestisce migration di stato
flatpak utente preesistente quando la distro cambia provider per
un'app (es. da flatpak a rpm).

**Us**: due hook complementari (commit `550c4f1`):
- `system-setup.hooks.d/15-cleanup-firefox-flatpak.sh` (root, oneshot
  via `ublue-system-setup.service`) — `flatpak uninstall --system
  org.mozilla.firefox`.
- `user-setup.hooks.d/15-cleanup-firefox-flatpak.sh` (per-utente, via
  `ublue-user-setup.service --user`) — `flatpak uninstall --user
  org.mozilla.firefox`.

Entrambi versionati con `version-script cleanup-firefox-flatpak
{system,user} 1` di `libsetup.sh`. Bump del numero versione → l'hook
rigira automaticamente al prossimo boot/login, senza intervento utente.

**Why it matters**: chi aggiorna da una bazzite-mx pre-Phase-8 ha
ancora la flatpak Firefox installata localmente. Senza cleanup hook,
si troverebbe DUE Firefox sul sistema (rpm + flatpak), e l'icon launcher
KDE potrebbe puntare al flatpak vecchio. Il pattern è generico: qualsiasi
futura migrazione "flatpak → rpm" può riutilizzare lo stesso layout.

## 14. RPM Fusion + 1Password integrati senza maintenance debt

**Upstream**:
- Bazzite e Bazzite-DX **non integrano** RPM Fusion del tutto.
- Aurora ha solo un loop *difensivo* (`build_files/dx/00-dx.sh:139`,
  `build_files/base/17-cleanup.sh:79`) che disabilita rpmfusion-* se
  per caso fossero abilitati, ma non vendora i `.repo` né installa
  pacchetti da Fusion.
- AmyOS è l'unica del ublue ecosystem che integra RPM Fusion
  attivamente, ma il modo in cui acquisisce i `.repo` non è esplicito
  in `install-apps.sh` (probabilmente eredità da base image), e per
  istallare solo `audacious` + `audacity-freeworld`.
- Per 1Password, nessuna distro ublue ha integrazione (la docs
  ufficiale 1Password chiede sempre `rpm --import URL` + creazione
  manuale di `.repo`).

**Us** (commit iniziale `12709cf`, refactor `8d9152f`): zero-debt
maintenance approach per entrambi i repo:
- `build_files/dx/47-rpmfusion-release.sh`: install
  `rpmfusion-nonfree-release-$(rpm -E %fedora)` come pacchetto rpm
  (5.9 KB). Il pacchetto shippa GPG keys per Fedora 2020/44/45/46/
  latest/rawhide e i 3 `.repo` files (release/updates/updates-testing).
  Sed disable di tutte le sezioni a baseline `enabled=0`.
- `build_files/dx/48-1password-key.sh`: `curl -fsSL` della key
  ufficiale `https://downloads.1password.com/linux/keys/1password.asc`
  ad ogni build. PGP block sanity check fallisce build se 1Password
  ritorna garbage.
- `system_files/etc/yum.repos.d/1password.repo` rimane vendored
  (è policy nostra, `enabled=0`, `repo_gpgcheck=1`).

**Why it matters**: zero responsabilità di key rotation lato nostro.
Quando RPM Fusion ruota la key (raro, ma succede a major Fedora),
il pacchetto release upstream la include automaticamente — `bootc
upgrade` la prende. Quando 1Password ruota la key, la prossima
rebuild hourly via watch-upstream la fetcha fresh. **Bazzite-DX e
AmyOS hanno questa stessa scelta accessibile ma vendorano** —
significa che il loro debt è latente, il nostro è strutturalmente
zero. Future-proof per Fedora 45/46 senza alcun intervento manuale.

## 15. `ujust install-{discord,1password}` opt-in pattern + reusable `_pkg_layered` helper

**Upstream**: il file `82-bazzite-apps.just` di Bazzite ha
ricette `install-coolercontrol`, `install-displaylink`,
`install-jetbrains-toolbox` ecc., ma **né `install-discord` né
`install-1password`**, e ogni ricetta ridefinisce inline la sua
funzione bash `layered()` (duplicazione). bazzite-dx non aggiunge
`install-*` recipes (il loro `95-bazzite-dx.just` ha solo
`dx-group`, `install-fonts`, `toggle-gamemode`). Aurora-DX e
AmyOS non shippano un justfile custom.

**Us**: primo justfile MX con due ricette opt-in distinte:
- `system_files/usr/share/ublue-os/just/95-bazzite-mx.just`
- `[private] _pkg_layered pkg` — helper **riutilizzabile** che usa
  `rpm-ostree status --json | jq` per check del booted deployment.
  Hardened con `// []` fallback (safe quando deployment ha 0
  pacchetti layered o non c'è un booted deployment, es. CI).
  A differenza del pattern Bazzite (function inline ridefinita
  per ricetta), il nostro è DRY: ogni nuova `install-*` recipe
  fa `if just _pkg_layered <pkg>; then ...; fi`.
- `[group("apps")] install-discord` (commit `12709cf`) — RPM Fusion
  non-free, `sed '0,/^enabled=0/{...}'` (solo main section, non
  debuginfo+source) e `sudo rpm-ostree install` esplicito.
- `[group("apps")] install-1password` (commit `ec1acf0`) — repo
  ufficiale 1Password (`downloads.1password.com`), file
  single-section quindi `sed 's/^enabled=0/enabled=1/'` semplice.
  GPG key vendoredata (fingerprint `3FEF9748469ADBE15DA7CA80AC2D6
  2742012EA22`) per supportare `repo_gpgcheck=1` senza
  `rpm --import` runtime.

**Why it matters**: Discord ha update settimanali e nag intrusivo
"Update Available" che su atomic distro l'utente non può ignorare
via `dnf update`. 1Password ha integrazione native messaging che
su flatpak è bloccata dal sandbox. Il modello opt-in via ujust
significa che chi non usa l'app non ha la repo abilitata → niente
metadata extra in `bootc upgrade`. Chi installa beneficia di
update automatici via `ujust update` senza intervento manuale
(la repo resta `enabled=1` post-install). Saremmo i primi del
ublue ecosystem con queste ricette **e** con un helper `_pkg_layered`
riutilizzabile (gli upstream duplicano la logica).

## How to extend this list

When adding a new Phase, deliberately ask: **does this give us an edge
over upstream `bazzite-dx`?** If yes, document it here with:
- Commit hash that introduces it.
- What upstream does (or doesn't do).
- What we do.
- Why it matters in practice (concrete user-visible benefit).

If no, it's still a fine Phase, but the win-list isn't the place for it.
