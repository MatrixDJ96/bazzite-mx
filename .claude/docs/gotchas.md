# Gotchas — canonical list

A discovered pitfall is documented here so the next session does not
re-discover it the hard way. Add new rows as they emerge, with the
date and the commit / context where the lesson was learned.

| # | Symptom | Root cause | Fix | First seen |
|---|---|---|---|---|

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
