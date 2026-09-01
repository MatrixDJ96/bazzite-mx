# Conventions

## Bash scripts (everything under `build_files/`)

- **Shebang — two families**: in-image scripts (`build_files/`, `system_files/` hooks) use
  `#!/usr/bin/bash` (Bazzite ships bash at that path); host-side scripts (`.claude/hooks/`,
  `.github/scripts/`) use `#!/usr/bin/env bash` (portable across dev hosts and CI runners).
- **Strict mode**: `set -euxo pipefail` for orchestration scripts and the numbered
  `build_files/mx/*.sh` install scripts. The `-x` is intentional — every command echoed in CI
  logs locates a failure precisely.
  - **Exception**: `validate-repos.sh` uses `set -eou pipefail` (no `-x`) because its own
    `echo` output is the report and `-x` would garble it. Matches Aurora upstream's
    `validate-repos`.
  - **Exception**: sourced helper libraries (`copr-helpers.sh`) use `set -euo pipefail` (no
    `-x`): the caller's own `-x` already echoes every command the helpers run.
- **Log grouping**: wrap the script body with `echo "::group:: ===$(basename "$0")==="` and
  `echo "::endgroup::"` so the GitHub Actions UI nests the output collapsibly.
- **Don't hide errors**: never `|| true` to silence failures unless the failure is genuinely
  benign (masking a non-existent service file is acceptable; a failing `install` is not).
- **Loops over arrays**: prefer `for item in "${ARRAY[@]}"; do ...; done` to repeated commands
  — easy to extend, easy to test.
- **Script enumeration**: iterate files matching a pattern via
  `mapfile -t list < <(find DIR -maxdepth 1 -type f -name 'PATTERN' | sort -V)`, never
  `for f in $(ls ...)` — the latter splits on whitespace and silently fails on empty matches
  under `set -e`. `sort -V` (version sort) orders `10-foo.sh` before `20-foo.sh` before
  `100-foo.sh`, unlike alphabetic sort.

## Writing base-image files

A build step that modifies a file the base image already ships writes into an overlayfs
**copied-up** inode, and the 6.17-azure kernel on runner image `ubuntu-24.04 20260816+` loses
page writeback of exactly those writes. In-build reads answer from warm page cache, so the
build stays green while the committed layer carries a NUL tail — the shape that shipped a
btree-damaged rpmdb in release `44.20260823` and a `ujust`-killing master justfile in
`44.20260826` (gotcha #34).

A file the build **creates** lives natively in the upper layer and is unaffected. Among the
tools that touch an existing file, only the ones writing a temporary and renaming it land on a
fresh inode — measured 2026-08-28 with `stat -c %i` on the host and inside an overlay
container:

| Idiom | Inode | Class |
|---|---|---|
| `sed -i`, `install`, `mv` (same-fs and cross-fs), `rsync`, `depmod`, `cp --remove-destination` | replaced | safe |
| `>>`, `cat tmp > file`, `cp src dst`, `tee`, `curl -o`, `truncate`, sqlite writes | kept | **exposed** |

**The rule**: a script whose last write to a base-image file uses an exposed idiom calls
`rewrite_fresh_inode` on that file before it exits.

```bash
# shellcheck disable=SC1091
source /ctx/build_files/shared/writeback-helpers.sh
...
grep -qxF "$line" "$FILE" || echo "$line" >> "$FILE"
rewrite_fresh_inode "$FILE"
```

`rewrite_fresh_inode` copies with `--preserve=mode,ownership,timestamps`, fsyncs, and renames —
so a stripped justfile keeps the `0644` `ujust` needs. Every writer of a file rewrites what it
wrote, so the guard survives a reordering of the numbered scripts.

A tool's side effect counts as a write: `dnf5 copr disable` flips `enabled=` in place, so
`copr_install_isolated` rewrites the COPR's `.repo` file — the one for `ublue-os/packages`
lands on a path the base image already ships, and `validate-repos.sh` enforces the very value
it carries.

For a database the tool owns, use its own atomic rewrite instead: `build.sh` step 4 runs
`VACUUM INTO` + `os.replace` over the rpmdb, then drops the `-wal` / `-shm` sidecars the vacuum
folded in. The other route is not to ship the database at all: `clean-stage.sh` empties
`/usr/lib/sysimage/libdnf5/`, which took libdnf5's transaction history off this surface.

Detection is the other half, and it lives in
[`.github/scripts/check-image-integrity.sh`](../.github/scripts/check-image-integrity.sh) — see
§ Smoke tests below.

## Comments in code

- **WHY, not WHAT** — well-named identifiers and `set -euxo pipefail` already tell you what
  each line does.
- Cite **provenance** in non-obvious patterns: "ported from Aurora upstream", "lifted 1:1 from
  bazzite-dx", "verified empirically 2026-05-02 against dnf5 5.x".
- Cite **discovered gotchas**: when a script works around a documented pitfall (e.g. the
  `sed enabled=1→0` rule for runtime-added .repo files, gotcha #2), its comment names the
  pitfall — load-bearing, because without it the next refactor reverts to the broken idiom and
  silently breaks repo isolation.
- Avoid "added for issue #X" comments — they rot; the PR / commit body is the right place.

## Git

### Commit messages

- **Conventional Commits**: `<type>(<scope>): <subject>`. The scope names the **domain** the
  commit touches, matching the history (`git log --format=%s`):
  - `feat(<domain>): …` — a domain landing: `feat(virt)`, `feat(firefox)`, `feat(sunshine)`,
    `feat(msi-ec)`, `feat(ci)`, `feat(pages)`, …
  - `fix(<domain>): …` / `refactor(<domain>): …` — bug fix / restructuring within a domain,
    same scope as the commit that introduced it.
  - `docs: …` — documentation only (scope optional).
  - `chore(...): …` — housekeeping, e.g. `chore(claude)` for harness config; scaffold-level
    chores go scopeless (`chore: scaffold …`).
- Subject ≤ 70 chars, imperative mood.
- Body explains the WHY, not the WHAT — reference upstream comparisons, measurement results,
  and discoveries (e.g. "verified on Bazzite 44.20260501 / dnf5 5.x").
- **No attribution trailer** (`Co-Authored-By`, `Generated-By`, `Assisted-By`, …) unless the
  user explicitly asks for it on a specific commit.

### Push behaviour

- **Always pause for user confirmation before `git push`** — even on a clean pre-flight, a push
  triggers 6 CI jobs and is visible to the world.
- **Never** `--force`, `--no-verify`, or `--amend` without an explicit ask.

### Commit splitting

- **One concern per commit**: a phase introducing both new functionality and a refactor splits
  into two commits (`feat(...)` + `refactor(...)`).
- **Mode changes** (chmod +x) belong with the file's introducing commit when possible;
  standalone "chmod +x drive-by" lines in a refactor commit body are acceptable.

## dnf5 quirks

The `setopt` silent no-op — the most critical quirk — is gotcha #2 in
[`gotchas.md`](gotchas.md); workaround: `sed -i 's/^enabled=1/enabled=0/g'`.

| Quirk | Consequence | Workaround |
|---|---|---|
| `dnf5 -y install --enablerepo=<id> …` is a **runtime-only override** | The .repo file's persistent `enabled=` value is unchanged | Pair with a vendored `enabled=0` repo file; install is one-shot, file remains correctly disabled |
| `dnf` (dnf4 binary) is a compat shim on F44+ | May not support some setopt syntaxes identically | Always invoke `dnf5` directly in build scripts |
| `dnf5 install URL` works | Lets us install packages with no upstream yum repo (e.g., GitKraken) | Use sparingly; document the trust model |

## Repo isolation invariant

Every third-party repo file in `system_files/etc/yum.repos.d/` ships `enabled=0`. The single
authoritative enumeration is `build_files/shared/third-party-repos.list`, one basename per
line. `validate-repos.sh` reads it and hard-fails the build on any listed repo left `enabled=1`
**or listed but absent from the image** — the list is authoritative in both directions: an
absent entry means a renamed upstream repo file or an install script that stopped shipping it,
and tolerating it leaves the renamed file unenforced (base `44.20260831` renamed
`fedora-multimedia.repo` to `negativo17-fedora-multimedia.repo`; the tolerant loop said nothing
and the regression surfaced only post-rechunk, 2026-09-01). A `?` prefix marks an optional
entry — enforced `enabled=0` when present, tolerated when absent — for repos the base has
shipped before and may ship again (`?fedora-coreos-pool.repo`). `reusable-build.yml` hands the
same file to `check-image-integrity.sh`, which re-proves both rules on the chunked image's cold
bytes — a torn tail that drops an `enabled=` line makes dnf treat the section as ENABLED, so
the warm check alone is not enough. Aurora upstream keeps the array inline in the script; the
file is the deliberate deviation that buys the cold half.

When adding a new third-party repo:

1. Vendor the .repo file in `system_files/etc/yum.repos.d/<name>.repo` with `enabled=0`.
2. Add `<name>.repo` to `build_files/shared/third-party-repos.list`.
3. Use `dnf5 -y install --enablerepo=<section> <pkg>` in the mx script.

The catch-all sweep at the bottom of `validate-repos.sh` is **informational only** — it lists
every other `.repo` file's enabled state without failing the build, because the core Fedora
repos (`fedora.repo`, `fedora-updates.repo`, `fedora-updates-archive.repo`) are legitimately
`enabled=1`. They are the only three left enabled in the shipped image, so a fourth line in
that sweep is a third-party repo nobody registered — the shape that let `terra-mesa.repo` ship
`enabled=1` unenforced until 2026-09-01. A base-image repo that must ship disabled is registered
in the list like any other and disabled by a `sed` in `clean-stage.sh`; upstream's own
`repos.override.d` route is invisible to both validators.

## COPR install pattern

Use `copr_install_isolated <user/copr> <package1> [package2…]` from
`build_files/shared/copr-helpers.sh`:

```
dnf5 -y copr enable <user/copr>
dnf5 -y copr disable <user/copr>
dnf5 -y install --enablerepo=copr:copr.fedorainfracloud.org:<user>:<copr> <packages>
```

The COPR is enabled briefly (so dnf can write the .repo file with metadata), immediately
disabled (so the file becomes `enabled=0`), then the runtime-only `--enablerepo=` flag pulls
the packages without flipping the file back.

For `*-release` style RPMs (e.g. a hypothetical `tailscale-release` dropping a .repo file via
post-install scriptlet), the third-party repo rule applies unchanged: vendor the dropped
`.repo` under `system_files/etc/yum.repos.d/` with `enabled=0`, register its basename in
`build_files/shared/third-party-repos.list`, and install with `--enablerepo=<section>`.

## Smoke tests (`build_files/tests/10-tests-mx.sh`)

- **One numbered file**, extended in-place per phase.
- Per-phase pattern:
  ```bash
  # --- Phase N: <domain> packages ---
  <DOMAIN>_RPMS=( pkg1 pkg2 ... )
  for p in "${<DOMAIN>_RPMS[@]}"; do
      rpm -q "$p" >/dev/null || { echo "FAIL: rpm $p missing"; exit 1; }
  done

  # --- Phase N: <domain> services ---
  <DOMAIN>_UNITS=( foo.service bar.socket )
  for u in "${<DOMAIN>_UNITS[@]}"; do
      state=$(systemctl is-enabled "$u" 2>/dev/null || echo missing)
      if [ "$state" != "enabled" ]; then
          echo "FAIL: $u not enabled (state=$state)"
          exit 1
      fi
  done
  ```
- The `state=$(... || echo missing)` pattern matters: `systemctl is-enabled` exits 0 also for
  `static`, `linked`, `indirect`, `alias` — the test wants `enabled` literally. The diagnostic
  `(state=$state)` in the FAIL message saves debugging time.
- File-existence checks: prefer `[ ! -x "$path" ]` for executables, plus a content check via
  `grep -q '<pattern>'` when the content matters.

### The cold post-rechunk check

Every assertion in `10-tests-mx.sh` is a **warm** read: it answers from the page cache the
build just filled, so it cannot see a torn tail on disk.
`.github/scripts/check-image-integrity.sh` re-proves the same artefacts on the chunked image,
whose read path surfaces the committed bytes. `reusable-build.yml` mounts it into
`localhost/chunked-img` and runs it right after the rechunk, before any GHCR push. `develop`
and PR builds never rechunk, so the same script runs there against `raw-img` (the sandbox
step): a warmer read that still catches the logical classes — script regressions, malformed
artefacts, lost lines.

It carries two nets, because they fail differently:

- a **NUL sweep** over every build-mutated text artefact — a torn tail wherever it lands. Each
  named path must exist and each glob group must match a file, so an upstream rename fails the
  check instead of emptying it;
- **per-artefact probes** for a tear that ends on a clean boundary, which the sweep cannot see:
  `PRAGMA integrity_check` on both sqlite databases plus their absent sidecars, a real
  `just --summary` parse of the master with its import tree, a JSON parse of `image-info.json`,
  the appended blocklist deny lines, each out-of-tree module resolving through the binary
  `modules.dep.bin` index, an empty `/usr/lib/sysimage/libdnf5` (clean-stage's build-state
  drop), the base's versionlock pins still present (a wiped `versionlock.toml` shipped once),
  and every repo section — of the `third-party-repos.list` entries and of the COPR/RPM Fusion
  name classes — reading as disabled under dnf5's own truth table (`0/false/no/off` only; a
  missing `enabled=` line or a torn-away section header reads as ENABLED). The recipes of the
  two `.just` files must all survive the parse: a truncated file parses fine with fewer.

Adding an artefact to the build adds it to the sweep list. A new or changed probe is proven on
a known-bad input before its first green run is trusted, and the proof is code, not a
procedure: `check-image-integrity.sh --self-test` applies one lesion per section inside a
throwaway container of the checked image (last section first, so each lesion is the first
failure the child run meets) and requires every section to die on its own message.
reusable-build.yml runs it after the cold check on every sandbox build. A new probe ships with
its lesion in the self-test list; a probe with no lesion is a probe nobody has seen fail.

## Vendoring third-party content

- **Default**: vendor the `.repo` file in git under `system_files/etc/yum.repos.d/` — an
  auditable diff in PR review.
- **Exception (URL-only RPMs)**: when the vendor publishes no yum repo, only a stable RPM URL,
  install via `dnf5 install <URL>` and document in the script why we deviate and what the trust
  model is. Current example: GitKraken
  (`https://release.gitkraken.com/linux/gitkraken-amd64.rpm`).

## When probing third-party download URLs

Use `curl -sL --range 0-1023 <url>` (GET partial 1KB), never `curl -I` (HEAD) — several CDNs
reject HEAD (GitKraken: HEAD returned 404, GET worked). Probing with GET also lets you `file` /
`xxd` the bytes to verify it's an RPM.

## File permissions

- Scripts under `build_files/mx/`, `build_files/shared/`, `build_files/tests/` → **mode 755**
  (`chmod +x`). systemd unit files → **mode 644**.
- Verify before commit: `git ls-files --stage | grep '^100755'`. Fix an accidental 644 script
  with `chmod +x <file> && git update-index --chmod=+x <file>`.

## VSCode user defaults

`system_files/etc/skel/.config/Code/User/settings.json` is **minimal**:

```json
{ "update.mode": "none" }
```

Only the atomic-correctness fix (VSCode's self-updater fights a read-only /usr). No font,
theme, or formatter opinions imposed at distro level — those are user choices.

## VSCode repo

- `gpgcheck=1` is correct on Bazzite 44 — verified 2026-05-01 that the Microsoft .asc key
  (0xBE1229CF, fingerprint BC528686B50D79E339D3721CEB3E94ADBE1229CF) imports cleanly during the
  first dnf5 transaction. Bazzite-DX upstream sets `gpgcheck=0` behind a "FIXME: signature
  broken" comment that describes an older dnf/rpm version.
- **General rule**: verify an upstream claim by reading the code and running a quick test
  before copying a pattern — an upstream `FIXME` or workaround may already be stale (the
  `gpgcheck` case above is the canonical instance).
