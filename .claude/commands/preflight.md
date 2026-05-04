---
description: Run a local podman pre-flight build of bazzite-mx (single flavour, no NVIDIA) before pushing to CI.
allowed-tools: Bash(podman build:*), Bash(podman images:*), Bash(podman run --rm:*), Bash(skopeo inspect:*), Bash(jq:*), Read
argument-hint: "[base_tag]"
---

Run a local pre-flight build of bazzite-mx for the `bazzite` (non-NVIDIA) flavour. This catches issues 5 minutes locally instead of after 15 minutes across 6 CI jobs.

Steps:
1. Resolve the latest stable Bazzite tag (or use $1 if provided as argument):
   ```bash
   BASE_TAG="${1:-$(skopeo inspect --no-tags docker://ghcr.io/ublue-os/bazzite:stable | jq -r '.Labels["org.opencontainers.image.version"]')}"
   ```
2. Run `podman build` with --build-args matching `.github/workflows/reusable-build.yml`:
   - `BASE_IMAGE=bazzite`
   - `BASE_TAG=<resolved>`
   - `IMAGE_NAME=bazzite-mx`
   - `IMAGE_VENDOR=matrixdj96`
   - `VERSION=<tag>`
   - `UPSTREAM_TAG=<tag>`
   - `--tag localhost/bazzite-mx:preflight`
3. Redirect stdout+stderr to `/tmp/bazzite-mx-preflight.log`.
4. Capture and propagate the build exit code: `BUILD_EXIT=$?; echo "BUILD_EXIT=$BUILD_EXIT" >> /tmp/bazzite-mx-preflight.log; exit $BUILD_EXIT`.
5. Run as `run_in_background: true` so the harness notifies on completion — do **not** poll with sleep loops.

When the background job finishes, summarize:
- `grep BUILD_EXIT /tmp/bazzite-mx-preflight.log`
- Last 20 lines of log (smoke test result, bootc lint summary)
- `podman images localhost/bazzite-mx:preflight` (image size)
- One-line verdict: ready-to-push / fix-needed (with file:line if the failure is identifiable)

Common failure modes to watch for, in order of frequency:
1. **Repo isolation**: validate-repos.sh fails because a third-party repo file was left `enabled=1`. Use `sed -i 's/^enabled=1/enabled=0/g' <file>` (NEVER `dnf5 config-manager setopt`, it's a no-op on addrepo files).
2. **Missing systemctl unit**: a phase tries to `systemctl enable foo.service` but the unit was not provided by any installed package. Verify the package actually ships the unit.
3. **dnf5 install URL fails**: the upstream URL changed or is rate-limiting. Verify with `curl -sL --range 0-1023 <url>` (HEAD often rejected by CDNs).

Reference: `CLAUDE.md` § "Build commands" + § "Discovered gotchas".
