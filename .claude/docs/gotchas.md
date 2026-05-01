# Gotchas — canonical list

A discovered pitfall is documented here so the next session does not
re-discover it the hard way. Add new rows as they emerge, with the
date and the commit / context where the lesson was learned.

| # | Symptom | Root cause | Fix | First seen |
|---|---|---|---|---|
| 1 | `dnf5 config-manager setopt <id>.enabled=0` returns 0 but the .repo file is unchanged | dnf5 5.x: setopt is a silent no-op on .repo files added via `addrepo --from-repofile=URL` or `--repofrompath` | `sed -i 's/^enabled=1/enabled=0/g' /etc/yum.repos.d/<file>.repo` — same idiomatic pattern used everywhere we touch a runtime-added .repo | Phase 2 build #1 (commit `ccb34c4` shipped with the bug; review caught it; fix in `caa7eae`) |
| 2 | `curl -I https://release.gitkraken.com/...` returns HTTP 404 | Server rejects HEAD method | `curl -sL --range 0-1023 <url>` (GET partial) — also lets you `file` the bytes to verify it's an RPM | Phase 4 scouting |
| 3 | Phase 1 v1 build failed: KCM branding test — "expected Variant=…, got ''" | `/usr/share/kcm-about-distro/kcm-about-distrorc` doesn't exist on Bazzite (Aurora-only path) | Branding made best-effort (only writes if file exists); test removed | Phase 1 |
| 4 | `systemctl enable swtpm-workaround.service` → "Unit … does not exist" | The COPR `ublue-os-libvirt-workarounds` v1.1+ consolidated the historical separate `swtpm-workaround.service` into the single `ublue-os-libvirt-workarounds.service` (which is a SELinux relabel oneshot) | Don't enable the missing unit. Modern swtpm + libvirt work without a separate workaround service. The Aurora upstream still references the old name in their build script — likely they have stale code we should not blindly copy | Phase 3 |
| 5 | `for s in $(ls -1v "$DX"/*.sh)` is brittle | classic word-splitting on whitespace, plus fragile under `set -e` if the glob matches zero files | `mapfile -t SCRIPTS < <(find "$DX" -maxdepth 1 -type f -name '[0-9]*-*.sh' | sort -V); for s in "${SCRIPTS[@]}"; do …; done` | Phase 1+2 review |
| 6 | The first attempt at a "validate-repos catch-all" failed the build because `fedora.repo` / `fedora-updates.repo` / `terra-mesa.repo` were enabled=1 | Core Fedora/Bazzite repos legitimately ARE enabled. The catch-all conflated "third-party repo enabled" (bad) with "core repo enabled" (good) | Catch-all is now informational only — it lists every other `.repo` file's state but does not fail the build. Hard enforcement remains for the explicit `OTHER_REPOS` list | Phase 3 hardening |
| 7 | bazzite-dx upstream's `vscode.repo` install sets `gpgcheck=0` with a `FIXME: signature broken on newer rpm policies` comment | The fix landed upstream; on Bazzite 44 / dnf5 5.x the Microsoft .asc key (0xBE1229CF, fingerprint BC528686B50D79E339D3721CEB3E94ADBE1229CF) imports cleanly during the first transaction touching the repo. Verified empirically 2026-05-01 | Keep `gpgcheck=1` in our vendored `vscode.repo` — strictly more secure than upstream | Phase 4 |
| 8 | Bazzite's `cockpit.service` `Requires=cockpit-container.service` but no such file exists in `/usr/lib/systemd/system/` | The unit is generated at boot from `/usr/share/containers/systemd/cockpit-container.container` (a podman quadlet) by `podman-systemd-generator` | Don't fight Bazzite's design. `ujust cockpit enable` works. Adding host-side `cockpit-*` RPMs is unnecessary because the containerized `quay.io/cockpit/ws:latest` bundles all standard modules | Phase 5 (skipped after this discovery) |
| 9 | `bootc container lint` warns `nonempty-boot: Found non-empty /boot: extlinux` after Phase 3 | `qemu-system-x86-core` drops an `extlinux` binary in `/boot` for VM bootloader templates | Non-blocking warning; accept it. If it ever needs to go, add a `find /boot -name extlinux -delete` to `clean-stage.sh`, but only with a clear rationale | Phase 3 |
| 10 | `podman build … > log 2>&1; echo BUILD_EXIT=$?` always reports 0 even when the build failed | Final `echo` is the last command; its exit-zero replaces the build's exit code in the shell's overall exit status | Use `BUILD_EXIT=$?; echo "BUILD_EXIT=$BUILD_EXIT"; exit $BUILD_EXIT` (the explicit `exit` propagates the real status). Or use `&&` to chain failure-honouring | Phase 4 build #1 |
| 11 | `paths-ignore` did not skip CI for a docs commit | Commit included `.claude/settings.json` and `.gitignore`, neither of which matches `**.md`, `LICENSE`, or `docs/**`. GitHub paths-ignore: workflow runs if **any** file fails to match | Either: (a) extend paths-ignore to cover `.claude/**` and `.gitignore` for future free docs commits, or (b) accept the redundant CI run and move on | 2026-05-02 docs commit `b868a0d` |
| 12 | AmyOS ships vendored `vscode.repo` with `enabled=1` (their philosophy), opposite to ours | Different distro philosophy — they trust the source and let it auto-update via rpm-ostree layering | We keep `enabled=0` and validate-repos enforces it. Diverge consciously, document the decision (we did, in `vscode.repo`'s context comment) | Phase 4 |

## Patterns to be wary of

These are not yet bugs we've hit, but they're shape of bugs we expect:

- **`thirdparty_repo_install()` reuse**: the function in `copr-helpers.sh`
  has been hardened (`sed` instead of `setopt`) but is currently unused.
  When Phase 6+ adds Tailscale or similar, that's the first real-world
  test of the helper. Watch for the usual culprits: file naming mismatch
  (5th arg overrides default `<repo_name>.repo`), GPG check flag missing,
  `dnf5 install --nogpgcheck --repofrompath` semantics.

- **systemd preset behaviour**: some COPR packages (e.g.,
  `ublue-os-libvirt-workarounds`) enable their unit via `systemd-preset`
  on install. Our explicit `systemctl enable` after the install is then
  redundant — but it's defense-in-depth and harmless. If a future preset
  ever ships `disable` for a unit we wanted enabled, the explicit enable
  saves us. Keep the redundancy intentional.

- **Network-fetched RPMs (GitKraken)**: every CI build re-downloads the
  RPM. Our trust model rests on `release.gitkraken.com` HTTPS not being
  hijacked. If we ever see a sudden image-size jump or a smoke-test
  unexpectedly pass with a different RPM version, suspect upstream
  CDN changes.

- **`/etc/skel/` content vs runtime user creation**: files we ship in
  `/etc/skel/.config/...` only land in `$HOME` when a user account is
  CREATED. Existing accounts (already-deployed users on bazzite-mx) will
  not gain new defaults from a shipped change to `/etc/skel/`. If a
  future change to settings.json needs to apply to existing users, we
  need a user-setup hook that copies the file into `$HOME` (Phase 8 will
  set up `ublue-setup-services` for this).
