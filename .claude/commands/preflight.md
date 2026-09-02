---
description: Local podman pre-flight build of one bazzite-mx flavour before any push.
allowed-tools: Bash(./.github/scripts/resolve-base.sh:*), Bash(podman build:*), Bash(podman image inspect:*), Bash(grep:*), Bash(tail:*)
argument-hint: "[bazzite|bazzite-nvidia-open]"
---

Build one flavour locally with the same recipe CI runs, and judge it on the exit status.
Default flavour: `bazzite`; pass `bazzite-nvidia-open` as `$1` for the other one.

1. Resolve the base exactly as CI does (the script is the single owner of the coordinates):
   ```bash
   FLAVOUR="${1:-bazzite}"
   eval "$(./.github/scripts/resolve-base.sh "$FLAVOUR")"
   echo "base_image=$base_image kernel_version=$kernel_version"
   ```
2. Build, logging to disk (`/tmp` is tmpfs on the fleet: the log goes to `/var/tmp`), and keep
   the build's own exit status — `tee` would otherwise hide it:
   ```bash
   podman build --pull=newer \
     --build-arg BASE_IMAGE="$base_image" \
     --build-arg IMAGE_NAME="$image_name" \
     --tag localhost/bazzite-mx:preflight . 2>&1 | tee /var/tmp/bazzite-mx-preflight.log
   BUILD_EXIT=${PIPESTATUS[0]}
   echo "BUILD_EXIT=$BUILD_EXIT" >> /var/tmp/bazzite-mx-preflight.log
   exit $BUILD_EXIT
   ```
   Run it with `run_in_background: true`; the harness notifies on completion.
3. When it finishes, report: `grep BUILD_EXIT /var/tmp/bazzite-mx-preflight.log`, the last 20
   log lines (smoke tests, `bootc container lint` summary), and
   `podman image inspect --format '{{.Size}}' localhost/bazzite-mx:preflight`.
4. Verdict in one line: ready for `develop` / fix needed (file:line when the log names it).

Cleanup, only when asked: `podman rmi localhost/bazzite-mx:preflight`. Never a bare
`podman image prune -f` — it also removes the user's other dangling images.
