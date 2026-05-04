# Gotchas — canonical list

A discovered pitfall is documented here so the next session does not
re-discover it the hard way. Add new rows as they emerge, with the
date and the commit / context where the lesson was learned.

| # | Symptom | Root cause | Fix | First seen |
|---|---|---|---|---|
| 1 | Phase 2 v1 build failed: KCM branding test — "expected Variant=…, got ''" | `/usr/share/kcm-about-distro/kcm-about-distrorc` doesn't exist on Bazzite (Aurora-only path). Initial workaround used a `[ -f ]` guard that made the branding step silently no-op. | Bazzite ships the file at `/etc/xdg/kcm-about-distrorc` (the Bazzite-DX-style location). `build_files/mx/00-image-info.sh` seds `Variant` and `Website` there + updates `image-info.json` (image-name + image-ref + image-vendor) and `/usr/lib/os-release` VARIANT_ID. Smoke test asserts all four values to prevent silent regression. | Phase 2 (branding) |
| 2 | `dnf5 config-manager setopt <id>.enabled=0` returns 0 but the .repo file is unchanged | dnf5 5.x: setopt is a silent no-op on .repo files added via `addrepo --from-repofile=URL` or `--repofrompath` | `sed -i 's/^enabled=1/enabled=0/g' /etc/yum.repos.d/<file>.repo` — same idiomatic pattern used everywhere we touch a runtime-added .repo | Phase 3 (container runtime) |

## Patterns to be wary of

These are not yet bugs we've hit, but they're shape of bugs we expect:

- **`thirdparty_repo_install()` reuse**: the function in `copr-helpers.sh`
  has been hardened (`sed` instead of `setopt`) but is not yet used.
  When a future Phase introduces a third-party `.repo` install via the
  helper, it'll be the first real-world test. Watch for the usual
  culprits: file naming mismatch, GPG check flag missing,
  `dnf5 install --nogpgcheck --repofrompath` semantics.

- **systemd preset behaviour**: when COPR packages enable units via
  `systemd-preset` on install, our explicit `systemctl enable` after
  the install is then redundant — but it's defense-in-depth and
  harmless. Keep redundancy intentional.

- **Network-fetched RPMs**: every CI build re-downloads any RPM fetched
  via URL. Trust model rests on the source's HTTPS not being hijacked.
  Watch for sudden image-size jumps or smoke-test regressions that
  could indicate a changed upstream artifact.
