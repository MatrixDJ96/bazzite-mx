---
description: Local podman pre-flight build of one bazzite-mx flavour before any push.
allowed-tools: Bash(./.github/scripts/preflight-build.sh:*), Bash(grep:*), Bash(tail:*)
argument-hint: "[bazzite|bazzite-nvidia-open|bazzite-nvidia] [--no-cache]"
---

Build one flavour locally with the same recipe CI runs, and judge it on the exit status.
Default flavour: `bazzite`; name `bazzite-nvidia-open` or `bazzite-nvidia` instead. After a
change under `build_files/` or `system_files/` add `--no-cache`: buildah keys a `RUN` on its
command string and parent layer, never on the content of a bind mount, so a cached run exits 0
in minutes without running the changed script (`docs/gotchas.md`).

1. Run the script, in the background; the harness notifies on completion.
   ```bash
   ./.github/scripts/preflight-build.sh $ARGUMENTS
   ```
   It resolves the base and writes the labels the way CI does, builds
   `localhost/bazzite-mx:preflight` with the log in `/var/tmp/bazzite-mx-preflight.log` (`/tmp`
   is a tmpfs here), refuses a log without the build scripts' own output (`build.sh: N scripts
   ran`, `tests: N passed`) or with a `FAIL:` line, probes the image with `check-image.sh` and
   ends with one `preflight ok:` line.
2. On a failure, read the log before the verdict.
   ```bash
   grep -E 'BUILD_EXIT|^FAIL:|Using cache' /var/tmp/bazzite-mx-preflight.log
   tail -20 /var/tmp/bazzite-mx-preflight.log
   ```
3. Give the verdict in one line: ready for `develop`, or the fix needed with `file:line` when
   the log names it.

Cleanup, only when asked: `podman rmi localhost/bazzite-mx:preflight`. Never a bare
`podman image prune -f`, which also removes the user's other dangling images.
