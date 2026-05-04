# CLAUDE.md — bazzite-mx project guide

Auto-loaded by Claude Code at session start. Acts as the **navigable index**
for all project knowledge. Detailed deep-dives live under
[`.claude/docs/`](.claude/docs/) — read the relevant file when its topic
comes up.

---

## Project overview

`bazzite-mx` is a personal **bootc atomic distribution** built on top of
Bazzite, mirroring Aurora-DX's build style and adding both Aurora-DX's
package superset and Bazzite-DX's gems. **Single-flavour by design**:
no `IMAGE_TIER` toggle, no `-dx` suffix variants. The build pipeline is
unconditional and applied always. Three GHCR images differ only in
`BASE_IMAGE`:

| Image | BASE_IMAGE | Use case |
|---|---|---|
| `bazzite-mx` | `bazzite` | non-NVIDIA hardware |
| `bazzite-mx-nvidia` | `bazzite-nvidia` | NVIDIA proprietary driver |
| `bazzite-mx-nvidia-open` | `bazzite-nvidia-open` | NVIDIA open kernel modules |

**Repo**: `MatrixDJ96/bazzite-mx` on GitHub, branch `main`. SSH remote.
**Owner**: Mattia Rombi (mattyro96@gmail.com).

---

## Status (per phase)

| Phase | Status | Notes |
|---|---|---|
| 1 — Scaffold | ✅ Done | build_files {shared,mx,tests}, helpers, validate-repos |
| 2 — Container runtime | ✅ Done | Docker CE + podman extras + podman-bootc + sockets |
| 3 — Virtualization | ✅ Done | libvirt + qemu + virt-manager + swtpm + waypipe + groups service. **Phase 9 follow-up (2026-05-04)**: build-time `libvirtd.service` enable + KVM kargs (`/usr/lib/bootc/kargs.d/01-bazzite-mx-virt.toml`: `kvm.ignore_msrs=1` + `kvm.report_ignored_msrs=0`) + override of upstream `setup-virtualization` recipe (gate `! rpm -q virt-manager` was permanently FALSE on our image) + virt-manager flatpak mask (blocklist + 2 cleanup hooks). |
| 4 — IDE | ✅ Done | vscode + gitkraken + git-credential-libsecret + minimal vscode settings |
| **5 — Cockpit** | ❌ **SKIPPED** | Bazzite ships cockpit as a podman quadlet (`quay.io/cockpit/ws:latest`) — host-side RPMs would duplicate. See [`.claude/docs/architecture.md`](.claude/docs/architecture.md) § Cockpit pattern |
| 6 — Dev/sysadmin CLI | ✅ Done | android-tools + bcc + **bcc-tools** + bpftrace + bpftop + sysprof + iotop-c + nicstat + numactl + trace-cmd + flatpak-builder + gh (upstream vendored repo). cosign already in Bazzite base. claude-code/kcli deferred. |
| 7 — Bazzite-DX gems | ✅ Done | Curated subset: only **ccache** + **ublue-setup-services** (COPR). Migrated `bazzite-mx-groups` from custom service+versioning to a system-setup hook under `/usr/share/ublue-os/system-setup.hooks.d/` using `libsetup.sh`. Skipped: ramalama/restic/rclone/zsh/tiptop/git-subtree (per use-case review); usbmuxd already in base. |
| 8 — Justfile + hooks | ✅ Done | Firefox via Mozilla RPM repo + flatpak exclusion/cleanup hooks; `95-bazzite-mx.just` with `[private] _pkg_layered` helper (hardened: outputs `yes`/`no` on stdout to avoid `just` "Recipe failed" noise); ujust opt-in `install-discord` (RPM Fusion non-free) + `install-1password` (vendored repo); zero-maintenance third-party keys (`rpmfusion-nonfree-release` pkg install + 1Password key build-time fetch); idempotent justfile import in master; vscode-extensions user-setup hook (Aurora+Bazzite-DX convergent 3 ext, hardened against libsetup.sh state-before-body race); gparted + ptyxis desktop apps. |
| 9 — Final hardening | ✅ Done | Full Bazzite-DX-style branding (image-name + image-vendor + image-ref + VARIANT_ID + KCM Variant + Website all aligned); README "Building locally" section (pre-flight command + link to `.claude/docs/`); cosign verification documented (manual `cosign verify --key cosign.pub …` — ujust recipe deliberately deferred to avoid namespace clash with Bazzite's `verify-image`). |
| 9 follow-ups (2026-05-03 → 04) | ✅ Done | (a) `install-{discord,1password}` ujust recipes: add `sudo rpm-ostree reload` after `sed`-flipping `.repo` files (`rpm-ostreed` daemon caches its view of `/etc/yum.repos.d/` at start). (b) Virt L2 hardening — see Phase 3 row. (c) **Sunshine reintegrated** as system RPM via `lizardbyte/beta` COPR (Bazzite removed it 2026-03-26 due to F43 stale builds; the COPR resumed F44 builds 2026-04-28). `build_files/mx/65-sunshine.sh` adds COPR install + `setcap cap_sys_admin+p` (KMS capture) + `--global disable` (Aurora pattern, opt-in via `ujust setup-sunshine enable`). Override of brew-flavored `82-bazzite-sunshine.just` with our RPM-flavored version. Nag `sunshine-brew.msg.json` removed. |

Long-form plan with checkboxes:
[`docs/superpowers/plans/2026-05-01-aurora-dx-style-porting.md`](docs/superpowers/plans/2026-05-01-aurora-dx-style-porting.md).

Cumulative wins over upstream `bazzite-dx`: see
[`.claude/docs/wins-over-upstream.md`](.claude/docs/wins-over-upstream.md)
(19 wins as of 2026-05-04).

---

## Where to look

| If you need to… | Read |
|---|---|
| Understand the build flow / layout / Cockpit decision | [`.claude/docs/architecture.md`](.claude/docs/architecture.md) |
| Write new bash, edit a script, add a third-party repo, extend smoke tests | [`.claude/docs/conventions.md`](.claude/docs/conventions.md) |
| Plan a phase, decide when to push, do a review round, handle CI | [`.claude/docs/workflow.md`](.claude/docs/workflow.md) |
| Diagnose a familiar-looking error (dnf5 setopt, HEAD 404, paths-ignore, …) | [`.claude/docs/gotchas.md`](.claude/docs/gotchas.md) |
| Understand how the user wants to collaborate | [`.claude/docs/preferences.md`](.claude/docs/preferences.md) |
| Pre-flight a build locally before push | [`.claude/commands/preflight.md`](.claude/commands/preflight.md) — `/preflight` slash command |

---

## Critical conventions (the absolute minimum to not break things)

1. **`dnf5 config-manager setopt <id>.enabled=0` is a SILENT NO-OP** on
   .repo files added via `addrepo --from-repofile=URL` or `--repofrompath`.
   Use `sed -i 's/^enabled=1/enabled=0/g' /etc/yum.repos.d/<file>.repo`.
   This is the single biggest landmine in the project; see
   [`.claude/docs/gotchas.md`](.claude/docs/gotchas.md) row #1.

2. **Every third-party `.repo` file ships `enabled=0`**. Vendor it in
   `system_files/etc/yum.repos.d/`, register the basename in
   `OTHER_REPOS` in `validate-repos.sh`, install via
   `dnf5 -y --enablerepo=<section> install <pkg>`. The validator hard-fails
   the build if a registered repo is left enabled.

3. **Pre-flight locally** with `podman build --build-arg BASE_IMAGE=bazzite …`
   **before** pushing. ~5 min vs ~15 min for a 6-job CI matrix. Always
   capture the build's exit code properly: `BUILD_EXIT=$?; exit $BUILD_EXIT`
   (a trailing `echo` swallows the real status).

4. **Pause for user confirmation before push**, even on a green pre-flight.
   Push triggers 6 CI jobs and is visible to the world.

5. **Conventional Commits** with `Co-Authored-By: Claude Opus 4.7 (1M context)
   <noreply@anthropic.com>` trailer. SSH for `origin` remote. Never
   `--force`, `--no-verify`, `--amend` without explicit ask.

6. **Language policy**: chat with the user is in Italian (with diacritics:
   `però`, `città`); all committed content (code, comments, doc files,
   commit messages) is in English for the global audience. Code
   identifiers always English. Full policy in
   [`.claude/docs/preferences.md`](.claude/docs/preferences.md) §Language
   policy.

7. **Provenance citations always**: when proposing a package or pattern,
   cite the source ("from Aurora-DX line X", "lifted from bazzite-dx",
   "my proposal validated by Y"). The user has caught hallucinated
   provenance — transparency is non-negotiable.

8. **Skip a phase when upstream handles it well** (Phase 5 / Cockpit is
   the canonical example). Document why in the plan doc; don't re-derive
   the decision next session.

For the full set of conventions (bash style, smoke test idiom, vendoring
rule, COPR pattern, comment policy), see
[`.claude/docs/conventions.md`](.claude/docs/conventions.md).

For the full workflow (when to do reviews, paths-ignore behaviour, fix-
forward policy, Watch Upstream Releases), see
[`.claude/docs/workflow.md`](.claude/docs/workflow.md).

---

## Repository layout (one-line summary)

```
Containerfile               # 3 RUN steps: build.sh → 10-tests-mx.sh → bootc lint
build_files/{shared,mx,tests}/
system_files/{etc,usr}/
.github/workflows/          # build-stable, build-testing, reusable-build, watch-upstream
docs/superpowers/           # plans/ + notes/
.claude/                    # this folder + settings.json + commands/preflight.md + docs/
cosign.{key,pub}            # .key gitignored
```

Full layout with file-by-file role:
[`.claude/docs/architecture.md`](.claude/docs/architecture.md).

---

## Quick command cheatsheet

```bash
# Pre-flight one flavour locally (~5 min)
podman build --file Containerfile \
  --build-arg BASE_IMAGE=bazzite \
  --build-arg BASE_TAG=$(skopeo inspect --no-tags \
      docker://ghcr.io/ublue-os/bazzite:stable \
      | jq -r '.Labels["org.opencontainers.image.version"]') \
  --build-arg IMAGE_NAME=bazzite-mx \
  --tag localhost/bazzite-mx:preflight .

# Push and watch CI
git push origin main
gh run list --repo MatrixDJ96/bazzite-mx --limit 4 \
  --json databaseId,workflowName,status,conclusion,headSha,createdAt \
  | jq -r '.[] | "\(.createdAt) | \(.workflowName) | run \(.databaseId) | \(.status)/\(.conclusion // "-") | \(.headSha[0:7])"'

# Inspect a built image's repo isolation
podman run --rm localhost/bazzite-mx:preflight \
  bash -c 'grep -h "^enabled=" /etc/yum.repos.d/*.repo | sort | uniq -c'

# Cleanup local
podman rmi localhost/bazzite-mx:preflight && podman image prune -f
```

---

## When in doubt

- **Verify upstream by reading code**, not by trusting comments. The
  `gpgcheck=0 FIXME` in bazzite-dx was outdated; we caught the fix.
- **Trust Bazzite's design** when the original plan conflicts with reality
  (cockpit-as-container is the canonical example).
- **Update [`.claude/docs/`](.claude/docs/) proactively** when discovering
  new conventions, gotchas, or preferences. The transcript will be lost;
  these files persist.
- **Prefer skipping** when upstream handles a concern well. Phases are not
  obligations.
