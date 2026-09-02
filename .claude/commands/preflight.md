---
description: Local podman pre-flight build of one bazzite-mx flavour before any push.
allowed-tools: Bash(./.github/scripts/resolve-base.sh:*),
  Bash(./.github/scripts/image-labels.sh:*), Bash(./.github/scripts/check-image.sh:*),
  Bash(git rev-parse:*), Bash(sed:*), Bash(mapfile:*), Bash(eval:*), Bash(podman:*),
  Bash(echo:*), Bash(xargs:*), Bash(rm:*), Bash(id:*), Bash(df:*), Bash(grep:*), Bash(tail:*)
argument-hint: "[bazzite|bazzite-nvidia-open|bazzite-nvidia] [--no-cache]"
---

Build one flavour locally with the same recipe CI runs, and judge it on the exit status.
Default flavour: `bazzite`; name `bazzite-nvidia-open` or `bazzite-nvidia` instead. After a
change under `build_files/` or `system_files/` add `--no-cache`: buildah keys a `RUN` on its
command string and parent layer, never on the content of a bind mount, so a cached run exits 0
in minutes without running the changed script (`docs/gotchas.md` § A local pre-flight can exit
0 without running a changed build script).

1. Free the space the build needs first: the previous image of this flavour and the new one are
   both on disk otherwise. The verdict of the previous run is already in its log, so nothing is
   lost. `IMAGE` below is `bazzite-mx` for `bazzite`, `bazzite-mx-nvidia-open` for
   `bazzite-nvidia-open`, `bazzite-mx-nvidia` for `bazzite-nvidia`; another flavour's image is
   left alone, the owner may be keeping it on purpose.
   ```bash
   podman rmi localhost/IMAGE:preflight 2> /dev/null
   podman images --filter dangling=true -q | xargs -r podman rmi
   rm -rf "${TMPDIR:-/var/tmp}/buildah-cache-$(id -u)"
   df -h /var | tail -1
   ```
   The second line does what `podman image prune -f` does: every dangling image of the storage
   goes, the user's too. Never `podman image prune -a`, which also removes the user's tagged
   images no container uses, or `podman system prune`, which removes their stopped containers.
2. Resolve the base and write the labels the way CI does, then build, in the background; the
   harness notifies on completion. `FLAVOUR` is the flavour named in the arguments, `bazzite`
   by default; `--no-cache`, when the arguments carry it, goes after `--pull=newer`.
   ```bash
   ./.github/scripts/resolve-base.sh FLAVOUR > /var/tmp/IMAGE-base.env
   ./.github/scripts/image-labels.sh /var/tmp/IMAGE-base.env "" "$(git rev-parse HEAD)" \
     > /var/tmp/IMAGE-labels.txt
   eval "$(cat /var/tmp/IMAGE-base.env)"
   version=$(sed -n 's/^org\.opencontainers\.image\.version=//p' /var/tmp/IMAGE-labels.txt)
   mapfile -t labels < <(sed 's/^/--label=/' /var/tmp/IMAGE-labels.txt)
   podman build --pull=newer --build-arg BASE_IMAGE="$base_image" \
     --build-arg IMAGE_NAME="$image_name" --build-arg VERSION="$version" "${labels[@]}" \
     --tag localhost/IMAGE:preflight . > /var/tmp/IMAGE-preflight.log 2>&1
   echo "BUILD_EXIT=$?" >> /var/tmp/IMAGE-preflight.log
   ```
   The log is `/var/tmp/IMAGE-preflight.log` (`/tmp` is a tmpfs on a bootc host), its last line
   the build's own exit status.
3. Judge the log: it passes with `BUILD_EXIT=0`, the build scripts' own lines
   (`build.sh: N scripts ran`, `tests: N passed`) and no `FAIL:` line; on a failure, read the
   log before the verdict.
   ```bash
   grep -E 'BUILD_EXIT|^FAIL:|Using cache|scripts ran|^tests: ' /var/tmp/IMAGE-preflight.log
   tail -20 /var/tmp/IMAGE-preflight.log
   ```
   On a passing log, probe the image the way CI does:
   ```bash
   ./.github/scripts/check-image.sh localhost/IMAGE:preflight /var/tmp/IMAGE-labels.txt
   ```
4. Give the verdict in one line: ready for `develop`, or the fix needed with `file:line` when
   the log names it.

The image is left in place for the tests that follow; the next run removes it in step 1.
