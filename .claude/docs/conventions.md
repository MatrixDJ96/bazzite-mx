# Conventions

## Bash scripts (everything under `build_files/`)

- **Shebang**: `#!/usr/bin/bash` (Bazzite ships bash here).
- **Strict mode**: `set -euxo pipefail` for orchestration scripts and the
  numbered `build_files/mx/*.sh` install scripts. The `-x` is intentional —
  we want every command echoed in CI logs so a failure can be located
  precisely.
  - **Exception**: `validate-repos.sh` uses `set -eou pipefail` (no `-x`)
    because its own `echo` output is the report and `-x` would garble it.
    This deviation is Aurora upstream's choice; we kept it for parity.
- **Log grouping**: wrap script body with
  `echo "::group:: ===$(basename "$0")==="` and `echo "::endgroup::"` so
  GitHub Actions UI nests the output collapsibly.
- **Don't hide errors**: never `|| true` to silence failures unless the
  failure is genuinely benign (e.g., masking a non-existent service file is
  acceptable; an `install` failing is not).
- **Loops over arrays**: prefer `for item in "${ARRAY[@]}"; do ...; done` to
  repeated commands. Easy to extend, easy to test.
- **Script enumeration**: when iterating files matching a pattern, use
  `mapfile -t list < <(find DIR -maxdepth 1 -type f -name 'PATTERN' | sort -V)`
  rather than `for f in $(ls ...)`. The latter splits on whitespace and
  silently fails on empty matches under `set -e`. The `sort -V` (version
  sort) ensures `10-foo.sh` comes before `20-foo.sh` before `30-foo.sh`
  before `100-foo.sh`, unlike alphabetic sort.

## Comments in code

- **WHY, not WHAT**. Well-named identifiers and `set -euxo pipefail` already
  tell you what each line does.
- Cite **provenance** in non-obvious patterns: "ported from Aurora upstream",
  "lifted 1:1 from bazzite-dx", "verified empirically 2026-05-02 against
  dnf5 5.x".
- Cite **discovered gotchas**: e.g., the `sed` pattern in
  `10-container-runtime.sh` has a 4-line comment explaining why setopt is a
  no-op on addrepo files. This is load-bearing — without it, the next person
  refactoring will revert to setopt and silently break repo isolation.
- Avoid "added for issue #X" comments. They rot. The PR / commit body is the
  right place.

## Git

### Commit messages

- **Conventional Commits**: `<type>(<scope>): <subject>`.
  - `feat(mx): …` — new functionality (a phase landing)
  - `refactor(mx): …` — restructuring without behaviour change (hardening,
    splits, vendoring)
  - `fix(mx): …` — bug fix in the build pipeline / smoke test / ricetta
  - `docs(plan): …` / `docs(repo): …` — documentation only
  - `ci(...)`, `chore(...)`
  - **Legacy note**: pre-Phase 8 commits used scope `(dx)` from when the
    project still had an `IMAGE_TIER=base|dx` axis. The history is left
    intact; new commits use `(mx)` for consistency with the single-flavour
    naming.
- Subject ≤ 70 chars, imperative mood.
- Body explains the WHY, not the WHAT. Reference upstream comparisons,
  measurement results, and discoveries (e.g., "verified on Bazzite
  44.20260501 / dnf5 5.x").
- **Co-authorship trailer** on every Claude-assisted commit:
  ```
  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  ```

### Push behaviour

- **Always pause for user confirmation before `git push`**. Even on a clean
  pre-flight, the push triggers 6 CI jobs and is visible to the world.
- **SSH** for the `origin` remote (memory-pinned user preference). HTTPS
  triggers `ksshaskpass` and breaks non-interactive pushes.
- **Never** `--force`, `--no-verify`, or `--amend` without an explicit ask.

### Commit splitting

- **One concern per commit**. If a phase introduces both new functionality
  and a refactor, split into two commits with clear messages (`feat(...)`
  + `refactor(...)`).
- **Mode changes** (chmod +x) belong with the file's introducing commit
  when possible; standalone "chmod +x drive-by" lines in a refactor commit
  body are acceptable.

## dnf5 quirks (CRITICAL — keep this in working memory)

| Quirk | Consequence | Workaround |
|---|---|---|
| `dnf5 config-manager setopt <id>.enabled=0` is a **silent no-op** on .repo files added via `addrepo --from-repofile=URL` or `--repofrompath` | Repo stays enabled in the image despite the call returning 0 | `sed -i 's/^enabled=1/enabled=0/g' /etc/yum.repos.d/<file>.repo` |
| `dnf5 -y --enablerepo=<id> install …` is a **runtime-only override** | The .repo file's persistent `enabled=` value is unchanged | Pair with a vendored `enabled=0` repo file; install is one-shot, file remains correctly disabled |
| `dnf` (dnf4 binary) is a compat shim on F44+ | May not support some setopt syntaxes identically | Always invoke `dnf5` directly in build scripts |
| `dnf5 install URL` works | Lets us install packages with no upstream yum repo (e.g., GitKraken) | Use sparingly; document the trust model |

## Repo isolation invariant

Every third-party repo file in `system_files/etc/yum.repos.d/` ships
`enabled=0`. `validate-repos.sh` hard-enforces this for the explicit
`OTHER_REPOS` list:

```
fedora-multimedia.repo
tailscale.repo
vscode.repo
docker-ce.repo
fedora-cisco-openh264.repo
fedora-coreos-pool.repo
terra.repo
```

When adding a new third-party repo:

1. Vendor the .repo file in `system_files/etc/yum.repos.d/<name>.repo` with
   `enabled=0`.
2. Add `<name>.repo` to `OTHER_REPOS` in `validate-repos.sh`.
3. Use `dnf5 -y --enablerepo=<section> install <pkg>` in the mx script.

The catch-all sweep at the bottom of `validate-repos.sh` is **informational
only** — it lists every other `.repo` file's enabled state but does not
fail the build, because core Fedora/Bazzite repos (`fedora.repo`,
`fedora-updates.repo`, `terra-mesa.repo`) are legitimately `enabled=1`.

## COPR install pattern

Use `copr_install_isolated <user/copr> <package1> [package2…]` from
`build_files/shared/copr-helpers.sh`. The function does:

```
dnf5 -y copr enable <user/copr>
dnf5 -y copr disable <user/copr>
dnf5 -y install --enablerepo=copr:copr.fedorainfracloud.org:<user>:<copr> <packages>
```

The COPR is enabled briefly (so dnf can write the .repo file with
metadata), immediately disabled (so the file becomes `enabled=0`), then the
runtime-only `--enablerepo=` flag during install pulls the packages without
flipping the file back.

For `*-release` style RPMs (e.g., a hypothetical `tailscale-release` that
drops a .repo file via post-install scriptlet), use `thirdparty_repo_install`
which sed's the resulting file rather than calling setopt.

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
- The `state=$(... || echo missing)` pattern matters: `systemctl is-enabled`
  exits 0 also for `static`, `linked`, `indirect`, `alias` — we want
  `enabled` literally. The diagnostic `(state=$state)` in the FAIL message
  saves debugging time.
- File-existence checks: prefer `[ ! -x "$path" ]` for executables, plus a
  content check via `grep -q '<pattern>'` if the content matters.

## Vendoring third-party content

- **Default**: vendor the `.repo` file in git under
  `system_files/etc/yum.repos.d/`. Auditable diff in PR review.
- **Exception (URL-only RPMs)**: when the upstream vendor doesn't publish a
  yum repo — only a stable RPM URL — install via `dnf5 install <URL>`.
  Document in the script why we deviate and what the trust model is. Current
  example: GitKraken (`https://release.gitkraken.com/linux/gitkraken-amd64.rpm`).

## When probing third-party download URLs

- Use `curl -sL --range 0-1023 <url>` (GET partial 1KB), not `curl -I`
  (HEAD). Several CDNs reject HEAD; we hit this with GitKraken (HEAD
  returned 404, GET worked). Probing with GET also lets you `file` /
  `xxd` the bytes to verify it's an RPM.

## File permissions

- Scripts under `build_files/mx/`, `build_files/shared/`, `build_files/tests/`
  → **mode 755** (`chmod +x`). systemd unit files → **mode 644**.
- Verify before commit: `git ls-files --stage | grep '^100755'`. If a script
  was created mode 644 by accident, fix with
  `chmod +x <file> && git update-index --chmod=+x <file>`.

## VSCode user defaults

In `system_files/etc/skel/.config/Code/User/settings.json`. Currently
**minimal**:

```json
{ "update.mode": "none" }
```

Only the atomic-correctness fix (VSCode's self-updater fights a read-only
/usr). No font, theme, or formatter opinions imposed at distro level —
those are user choices.

## VSCode repo

- `gpgcheck=1` is correct on Bazzite 44 — verified 2026-05-01 that the
  Microsoft .asc key (0xBE1229CF, fingerprint
  BC528686B50D79E339D3721CEB3E94ADBE1229CF) imports cleanly during the
  first dnf5 transaction. Bazzite-DX upstream sets `gpgcheck=0` due to a
  historical "FIXME: signature broken" — that comment is outdated for our
  target.
