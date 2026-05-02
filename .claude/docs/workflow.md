# Workflow

## Phase development cadence

1. **Plan + scout**: read upstream sources (Aurora, Bazzite, Bazzite-DX,
   AmyOS) for the packages/files in scope. Verify what's already in the
   Bazzite base image (`podman run --rm ghcr.io/ublue-os/bazzite:<TAG> rpm -q
   …`). Skip what's already handled well by upstream.
2. **Implement**: edit/add files for the new domain. One numbered MX script
   per domain (`<NN>-<domain>.sh`) under `build_files/mx/`, plus any
   `system_files/` content.
3. **Extend smoke tests**: add `<DOMAIN>_RPMS` / `<DOMAIN>_UNITS` arrays to
   `build_files/tests/10-tests-mx.sh`. Tests are part of the build, not a
   separate harness.
4. **Pre-flight locally**: run a `podman build` for the `bazzite` flavour
   (no NVIDIA — the riskiest single shot covers ~95% of failure modes).
   ~5 min. Use `/preflight` slash command if available.
5. **Iterate** if the pre-flight fails. Do NOT push a red build to CI; the
   pre-flight is the cheapest debugging surface.
6. **Commit** when pre-flight green. Conventional Commits, descriptive
   body, Co-Authored-By trailer.
7. **Pause for user confirmation** before pushing. Even a green pre-flight
   should not auto-trigger 6 CI jobs without explicit go-ahead.
8. **Push** → CI matrix (3 flavours × 2 streams = 6 jobs).
9. **Monitor** via a polling background bash script (`gh run view --json`
   loop with `sleep 60`). The harness notifies on completion; do not
   manually check repeatedly.
10. **Verify** all 6 jobs `success`. Otherwise debug from logs and iterate.
11. **Cleanup local images** after CI confirmation
    (`podman rmi <preflight-tag> && podman image prune -f`).

## When to do a code review round

A formal review (via `feature-dev:code-reviewer` agent or self-review with
fresh eyes) is justified after:

- A phase that introduces **multiple new patterns** (Phase 2: container
  runtime + COPR pattern + repo isolation; Phase 3: virt + groups service
  + new `system_files/` shipping pattern).
- **Any time we suspect** "this might have bugs we're not seeing yet".
- **Before each significant Phase**, even if the new phase looks small —
  it forces explicit verification of patterns we're carrying forward.

What review historically caught (as of 2026-05-02):
- Phase 1+2 review (5 issues): dnf5 setopt no-op, brittle `for s in $(ls)`,
  validate-repos catch-all design, supply-chain vendoring of docker-ce.repo,
  dnf vs dnf5 inconsistency.
- Phase 3 review (2 issues): missing `After=local-fs.target` on groups
  service, `is-enabled` exit code semantics.

After a review, **fix immediately** — do not let issues stack.

## When to skip a phase

If upstream Bazzite (or upstream Aurora-DX or AmyOS) handles a domain
better than what we'd produce, **skip**. Phase 5 (Cockpit) is the canonical
example — Bazzite ships cockpit as a containerized service via a quadlet,
self-updating, with all standard modules. Layering host-side cockpit-machines
RPM would only duplicate what the container serves.

When you skip, document **why** in the plan doc and in CLAUDE.md / status
table. Future sessions should not re-derive the decision.

## CI behaviour to know about

### `paths-ignore`

Both `build-stable.yml` and `build-testing.yml` have:
```yaml
paths-ignore:
  - "**.md"
  - "LICENSE"
  - "docs/**"
```

GitHub semantics: workflow runs if **any** file fails to match. So a commit
touching only `*.md` files inside `docs/` does NOT trigger a build. But a
commit touching `.gitignore` OR `.claude/settings.json` (neither matches a
pattern above) DOES trigger a build.

If we ever extend paths-ignore (e.g., to add `.claude/**`, `.gitignore`),
the commit doing so still triggers ONE build because workflow files
themselves don't match paths-ignore. After that, future docs-only commits
become free.

### Concurrency

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}-${{ inputs.stream_name }}
  cancel-in-progress: true
```

A new push to `main` cancels any in-flight runs for the same workflow + ref
+ stream. So if you push twice in quick succession (e.g., feat + fix), only
the **latest commit's runs** complete; the intermediate are auto-cancelled.

This is intentional — the only state we care about is HEAD's correctness.

### Watch Upstream Releases

A separate workflow runs hourly via `cron`. It detects new Bazzite stable /
testing releases and re-triggers our `build-*.yml` against the same commit
to refresh the image with the new base. So our published image lags the
upstream by ≤ 1 hour for stable, ≤ 1 hour for testing.

This means **GitKraken (URL-fetched RPM) auto-updates within 1 hour** of a
new GitKraken release, because every triggered build re-fetches the URL.

### Cosign signing

Each successful build job signs the pushed image **by digest** with cosign,
using the secret `SIGNING_SECRET` (private key counterpart of `cosign.pub`
in this repo). Verifying a deployed image:

```bash
cosign verify --key cosign.pub ghcr.io/matrixdj96/bazzite-mx:latest
```

The local `cosign.key` is gitignored — only present on the maintainer's
machine and in GitHub secrets.

## Communication during a session

### When user asks a "where did this come from?" question

Always answer with **file:line** evidence, not "I think it's standard".
Three commands cover most provenance checks:

```bash
# Was this in Aurora upstream's DX install?
grep -n '<token>' /run/media/matrixdj96/Archivio/Projects/OS/aurora/build_files/dx/00-dx.sh

# Was it in Bazzite-DX?
grep -n '<token>' /run/media/matrixdj96/Archivio/Projects/OS/bazzite-dx/build_files/20-install-apps.sh

# Is it already in Bazzite base?
podman run --rm ghcr.io/ublue-os/bazzite:<TAG> bash -c 'rpm -q <pkg>'
```

If the answer is "I proposed it from training data", say so — cite the
reasoning, but don't pretend it's from upstream. The user has caught
hallucinated provenance multiple times in this session and trust depends
on transparency.

### When proposing additions

Format: a small table comparing **cost** / **value** / **provenance**, with
an explicit recommendation. Example:

| Item | Origine | Costo | Valore | Mio consiglio |
|---|---|---|---|---|
| `flatpak-builder` | Aurora-DX + Bazzite-DX | 5 min, ~80 MB | medio | dentro |
| `git-credential-libsecret` | mia proposta (validata in Aurora base) | 2 min, ~50 KB | medio-alto | dentro |

This frames the user's decision as picking from clearly-attributed options,
not approving an opaque list.

### When the user pushes back

Re-verify the claim from the source. The user is often right when they
question something — especially about taxonomy ("does GitKraken belong in
30-ide.sh?"), provenance ("did you take this from Aurora-DX or just
guess?"), or scope ("do we really need this?"). Apologize briefly if the
verification proves you wrong, then fix.

## Fix-forward policy

When a hardening issue is discovered post-ship (review round, user
question, CI failure):

- **Fix in a separate refactor commit**, not via `git commit --amend` or
  `git push --force`. The history is clearer and reverts are safer.
- The fix commit's body should reference the discovering source ("from a
  code review of Phase 3", "from a user question after Phase 4 ship").
- If multiple small fixes land together, group them by theme in one
  commit (e.g., `caa7eae refactor(dx): harden repo isolation, script
  loop, and dnf5 consistency` bundled 4 review findings).

## Session etiquette

- The user explicitly says "vai" / "procedi" before destructive ops
  (commit, push, rmi). Don't act preemptively.
- The user appreciates concise verdicts ("PROCEED" / "FIX FIRST") more
  than long debates. Pick a side, give the reasoning in 2 sentences.
- Sessions can run very long when productive. Don't pre-emptively suggest
  stopping unless there's a clear natural break. The user signals stop
  time explicitly ("ti devo chiedere di chiudere", or context like
  "stanotte basta").
