# Gotchas — canonical list

A discovered pitfall is documented here so the next session does not
re-discover it the hard way. Add new rows as they emerge, with the
date and the commit / context where the lesson was learned.

| # | Symptom | Root cause | Fix | First seen |
|---|---|---|---|---|
| 1 | Phase 2 v1 build failed: KCM branding test — "expected Variant=…, got ''" | `/usr/share/kcm-about-distro/kcm-about-distrorc` doesn't exist on Bazzite (Aurora-only path). Initial workaround used a `[ -f ]` guard that made the branding step silently no-op. | Bazzite ships the file at `/etc/xdg/kcm-about-distrorc` (the Bazzite-DX-style location). `build_files/mx/00-image-info.sh` seds `Variant` and `Website` there + updates `image-info.json` (image-name + image-ref + image-vendor) and `/usr/lib/os-release` VARIANT_ID. Smoke test asserts all four values to prevent silent regression. | Phase 2 (branding) |
| 2 | `dnf5 config-manager setopt <id>.enabled=0` returns 0 but the .repo file is unchanged | dnf5 5.x: setopt is a silent no-op on .repo files added via `addrepo --from-repofile=URL` or `--repofrompath` | `sed -i 's/^enabled=1/enabled=0/g' /etc/yum.repos.d/<file>.repo` — same idiomatic pattern used everywhere we touch a runtime-added .repo | Phase 3 (container runtime) |
| 3 | `systemctl enable swtpm-workaround.service` → "Unit … does not exist" | The COPR `ublue-os-libvirt-workarounds` v1.1+ consolidated the historical separate `swtpm-workaround.service` into the single `ublue-os-libvirt-workarounds.service` (which is a SELinux relabel oneshot) | Don't enable the missing unit. Modern swtpm + libvirt work without a separate workaround service. The Aurora upstream still references the old name in their build script — likely they have stale code we should not blindly copy | Phase 4 (virt) |
| 4 | `bootc container lint` warns `nonempty-boot: Found non-empty /boot: extlinux` after Phase 4 | `qemu-system-x86-core` drops an `extlinux` binary in `/boot` for VM bootloader templates | Non-blocking warning; accept it. If it ever needs to go, add a `find /boot -name extlinux -delete` to `clean-stage.sh`, but only with a clear rationale | Phase 4 (virt) |
| 5 | `ujust setup-virtualization virt-on` does nothing on bazzite-mx | Bazzite's upstream recipe is gated on `if ! rpm -q virt-manager \| grep -P "^virt-manager-"` — meaning **only** runs the kargs/swtpm/hooks setup if virt-manager is NOT RPM-installed. On bazzite-mx, `20-virtualization.sh` installs virt-manager as RPM at build time, so the gate is permanently FALSE and the entire setup branch is skipped — silent no-op | (a) build-time enable libvirtd.service in `20-virtualization.sh` so the basic stack works on first boot without any recipe; (b) ship build-time kargs via `system_files/usr/lib/bootc/kargs.d/01-bazzite-mx-virt.toml`; (c) ship our own `system_files/usr/share/ublue-os/just/84-bazzite-virt.just` overriding upstream's, with the gate dropped and the flatpak-install line removed (we have RPM). VFIO/kvmfr/usbhp blocks kept verbatim | Phase 4 (virt L2 hardening) |
| 6 | `dnf5 install iotop` succeeds, but `rpm -q iotop` returns "not installed" | F44 replaced the Python `iotop` with the C rewrite `iotop-c-1.31`. `iotop` is now an alias provider that resolves to `iotop-c`. The binary installed at `/usr/bin/iotop` keeps the historic name; the package name does not. | Smoke test asserts `rpm -q iotop-c`, install line still uses `dnf5 install iotop` (alias is fine for install resolution) | Phase 6 (CLI) |
| 7 | `curl -I https://release.gitkraken.com/...` returns HTTP 404 | Server rejects HEAD method | `curl -sL --range 0-1023 <url>` (GET partial) — also lets you `file` the bytes to verify it's an RPM | Phase 5 (IDE — fetched while validating GitKraken provenance) |
| 8 | `docker run` on a fresh deployment fails with "permission denied while trying to connect to the Docker daemon socket" even though `docker-ce` is installed and `docker.socket` is enabled | `docker-ce` from Docker Inc creates the `docker` group via an rpm postinstall scriptlet (`groupadd --system docker`). On rpm-ostree atomic systems, package postinstall scriptlets are SUPPRESSED to keep the OCI layer reproducible — so the group is never created. The `bazzite-mx-groups` hook then logs `WARNING: group docker not in /usr/lib/group; skipping` (visible in journal of first boot) and silently no-ops the docker membership grant. Aurora and Bazzite-DX inherit this gap (verified: neither ships a sysusers.d for docker). | Ship `/usr/lib/sysusers.d/bazzite-mx-docker.conf` with a single line `g docker -` (creates the group via systemd-sysusers at sysinit.target, before our hook runs). Bump `version-script bazzite-mx-groups system N` to invalidate the cached state on existing installations so the hook re-runs and adds wheel users to the now-existing docker group. | Phase 9 (bazzite-extras) |
| 9 | `ujust install-<x>` recipes shipped in `95-bazzite-mx.just` are not visible to ujust | Bazzite's master `/usr/share/ublue-os/justfile` uses explicit `import` directives (no glob). Files in `/usr/share/ublue-os/just/` not registered in the master are silently ignored. | Add a build-time append step (`build_files/mx/55-justfile-import.sh`) that idempotently registers our justfile in the master via `grep -qxF \|\| echo >> master`. Bazzite-DX and AmyOS do the same but without idempotency check. | Phase 10 (justfile) |
| 10 | Running `ujust install-1password` (or any `install-*` that calls a private helper) prints `error: Recipe '_pkg_layered' failed on line N with exit code 1` even when the install proceeds correctly | `just` always emits that line whenever a sub-recipe exits non-zero, even when the caller wraps the call in `if`. Our `_pkg_layered` helper used `jq -e` exit codes as a boolean signal — idiomatic in bash, but here it polluted the install-* output with a misleading "error" line. | Switch the helper to communicate via stdout: `@if jq -e ...; then echo yes; else echo no; fi`, always exits 0. Callers compare the string with `[ "$(just _pkg_layered <pkg>)" = "yes" ]`. Same DRY benefit, zero spurious lines. | Phase 10 (justfile) |

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
