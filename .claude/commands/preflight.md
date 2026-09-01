---
description: Run a local podman pre-flight build of bazzite-mx (single flavour, no NVIDIA) before pushing to CI.
allowed-tools: Bash(podman build:*), Bash(podman images:*), Bash(podman run --rm:*), Bash(skopeo inspect:*), Bash(jq:*), Bash(grep:*), Bash(./.github/scripts/resolve-kernel-coords.sh:*), Read
argument-hint: "[base_tag] [--cold-check]"
---

Run a local pre-flight build of bazzite-mx for the `bazzite` (non-NVIDIA) flavour. This catches
issues 5 minutes locally instead of after 15 minutes across 6 CI jobs.

Steps:
1. Resolve the latest stable Bazzite tag (or use $1 if provided as argument), then the akmods
   carrier coordinates through the same resolver CI runs — the single owner of the akmods tag
   schema, so a pre-flight builds against the carrier the matrix picks:
   ```bash
   BASE_TAG="${1:-$(skopeo inspect --retry-times 3 --no-tags docker://ghcr.io/ublue-os/bazzite:stable | jq -r '.Labels["org.opencontainers.image.version"]')}"
   COORDS=/tmp/bazzite-mx-kernel-coords.env
   : > "$COORDS"
   GITHUB_OUTPUT="$COORDS" ./.github/scripts/resolve-kernel-coords.sh bazzite "$BASE_TAG"
   # shellcheck disable=SC1090
   source "$COORDS"   # kernel_version, kernel_flavor, fedora_version
   ```
2. Run the `podman build` of README.md § "How it's built and shipped" VERBATIM — it is the
   single owner of the recipe: all ten build-args CI passes (`BASE_IMAGE`, `BASE_TAG`,
   `IMAGE_NAME`, `IMAGE_VENDOR`, `VERSION`, `UPSTREAM_TAG`, `UPSTREAM_DIGEST`,
   `KERNEL_VERSION`, `KERNEL_FLAVOR`, `FEDORA_VERSION`), the `tee` into
   `/tmp/bazzite-mx-preflight.log`, and `BUILD_EXIT=${PIPESTATUS[0]}`. Do not re-derive the
   argument list here: a missing arg ships empty labels and a green build.
3. When `build_files/` changed since the last pre-flight, bump `VERSION`
   (`"${BASE_TAG}-verifyN"`) or the layer cache replays the old scripts (gotcha #36).
4. Propagate the exit code: `echo "BUILD_EXIT=$BUILD_EXIT" >> /tmp/bazzite-mx-preflight.log;
   exit $BUILD_EXIT`.
5. Run as `run_in_background: true` so the harness notifies on completion — do **not** poll
   with sleep loops.
6. **Optional cold-check stage** — only when the user passes `--cold-check`: after a green
   build, run the unified integrity check against the committed preflight image, exactly as the
   CI sandbox step does (same script, same repo-list hand-off, no rechunk — the torn-writeback
   class the CI rechunk surfaces is specific to the runner kernel and cannot reproduce on a
   healthy local one; this stage covers the logical classes: script regressions, malformed
   artefacts, lost lines):
   ```bash
   THIRD_PARTY_REPOS=$(grep -vE '^[[:space:]]*(#|$)' build_files/shared/third-party-repos.list)
   podman run --rm \
       --env THIRD_PARTY_REPOS="$THIRD_PARTY_REPOS" \
       --volume "$PWD/.github/scripts/check-image-integrity.sh:/tmp/check-image-integrity.sh:ro,Z" \
       localhost/bazzite-mx:preflight bash /tmp/check-image-integrity.sh
   ```
   Judge on the exit status; the last line of a clean run is `image integrity ok`.

When the background job finishes, summarize:
- `grep BUILD_EXIT /tmp/bazzite-mx-preflight.log`
- Last 20 lines of log (smoke test result, bootc lint summary)
- `podman images localhost/bazzite-mx:preflight` (image size)
- One-line verdict: ready-to-push / fix-needed (with file:line if the failure is identifiable)
- Cleanup, when the user asks for it, is the scoped pair from the README (`podman rmi` of the
  tag + `podman image prune -f --filter label=org.opencontainers.image.title=bazzite-mx`) —
  never a bare `podman image prune -f`, which also takes the user's other dangling images.

Common failure modes to watch for, in order of frequency:
1. **Repo isolation**: validate-repos.sh fails because a third-party repo file was left
   `enabled=1`. Use `sed -i 's/^enabled=1/enabled=0/g' <file>` — NEVER
   `dnf5 config-manager setopt` (gotcha #2 in `docs/gotchas.md`).
2. **Missing systemctl unit**: a phase tries to `systemctl enable foo.service` but the unit was
   not provided by any installed package. Verify the package actually ships the unit.
3. **dnf5 install URL fails**: the upstream URL changed or is rate-limiting. Verify with
   `curl -sL --range 0-1023 <url>` (HEAD often rejected by CDNs).
4. **akmods carrier missing**: the resolver aborts with `no akmods tag carries kernel …`
   because upstream published the base image before its akmods carrier. Wait for the carrier
   (gotcha #32 in `docs/gotchas.md`); nothing in this repo fixes it.

Reference: `AGENTS.md` § Quick command cheatsheet + `docs/gotchas.md`.
