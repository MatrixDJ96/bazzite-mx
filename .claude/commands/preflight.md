---
description: Local podman pre-flight build of one bazzite-mx flavour before any push.
allowed-tools: Bash(./.github/scripts/resolve-base.sh:*), Bash(./.github/scripts/image-labels.sh:*), Bash(./.github/scripts/check-image.sh:*), Bash(podman build:*), Bash(podman image inspect:*), Bash(grep:*), Bash(tail:*)
argument-hint: "[bazzite|bazzite-nvidia-open|bazzite-nvidia]"
---

Build one flavour locally with the same recipe CI runs, and judge it on the exit status.
Default flavour: `bazzite`; pass `bazzite-nvidia-open` or `bazzite-nvidia` as `$1`.

1. Resolve the base and write the labels the way CI does.
   ```bash
   FLAVOUR="${1:-bazzite}"
   ./.github/scripts/resolve-base.sh "$FLAVOUR" | tee /var/tmp/bazzite-mx-base.env
   eval "$(cat /var/tmp/bazzite-mx-base.env)"
   ./.github/scripts/image-labels.sh /var/tmp/bazzite-mx-base.env "" "$(git rev-parse HEAD)" > /var/tmp/bazzite-mx-labels.txt
   VERSION=$(sed -n 's/^org\.opencontainers\.image\.version=//p' /var/tmp/bazzite-mx-labels.txt)
   echo "base_image=$base_image kernel_version=$kernel_version version=$VERSION"
   ```
2. Build, logging to `/var/tmp` because `/tmp` is a tmpfs here, and keep the build's own exit
   status rather than `tee`'s.
   ```bash
   mapfile -t label_args < <(sed 's/^/--label=/' /var/tmp/bazzite-mx-labels.txt)
   podman build --pull=newer \
     --build-arg BASE_IMAGE="$base_image" \
     --build-arg IMAGE_NAME="$image_name" \
     --build-arg VERSION="$VERSION" \
     "${label_args[@]}" \
     --tag localhost/bazzite-mx:preflight . 2>&1 | tee /var/tmp/bazzite-mx-preflight.log
   BUILD_EXIT=${PIPESTATUS[0]}
   echo "BUILD_EXIT=$BUILD_EXIT" >> /var/tmp/bazzite-mx-preflight.log
   exit $BUILD_EXIT
   ```
   Run it with `run_in_background: true`; the harness notifies on completion.
3. Read the log before trusting the exit status. Buildah keys a `RUN` on its command string
   and parent layer, never on the content of a bind mount. After a change under `build_files/`
   or `system_files/` a cached run prints `Using cache`, exits 0 in minutes and commits the
   previous image id (`docs/gotchas.md`). The proof that the scripts ran is their own output
   (`kmod <name>:`, `tests: N passed`) and a fresh image id; when the id repeats, rerun with
   `--no-cache`.
   ```bash
   grep BUILD_EXIT /var/tmp/bazzite-mx-preflight.log
   tail -20 /var/tmp/bazzite-mx-preflight.log
   podman image inspect --format '{{.Size}}' localhost/bazzite-mx:preflight
   ```
4. Probe the built image the way CI probes the sandbox image.
   ```bash
   ./.github/scripts/check-image.sh localhost/bazzite-mx:preflight /var/tmp/bazzite-mx-labels.txt
   ```
5. Give the verdict in one line: ready for `develop`, or the fix needed with `file:line` when
   the log names it.

Cleanup, only when asked: `podman rmi localhost/bazzite-mx:preflight`. Never a bare
`podman image prune -f`, which also removes the user's other dangling images.
