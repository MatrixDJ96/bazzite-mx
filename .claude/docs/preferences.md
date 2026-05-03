# User preferences

How the user (Mattia, MatrixDJ96) wants to collaborate on this project.
Observed patterns from the porting session 2026-05-01 / 2026-05-02 and
explicit statements. Update as new preferences emerge.

## Language policy

**Single most important convention to internalize:**

- **Conversational language (assistant ↔ user, in chat): Italian.**
  All chat dialogue happens in Italian. Required diacritics: `però`,
  `città`, `così` — never `pero`, `citta`, `cosi`.
- **Committed content (code comments, commit messages, doc files,
  settings.json, README): English.** The repo is a public global
  project; non-Italian contributors and users must be able to read
  every file. No mixed-language artifacts in git.

Code identifiers (variable names, package names, file paths, command
flags) always stay in their original form (English).

If you write Italian in a file that gets committed, that's a bug to
fix. If you reply in English in chat with the user, that's also a bug
— they prefer the conversation in Italian.

## Communication style

- **`★ Insight` blocks** (Unicode square + horizontal lines) for
  educational / explanatory content:
  ```
  ★ Insight ─────────────────────────────────────
  [2-3 specific points about the codebase or the change just made]
  ─────────────────────────────────────────────────
  ```
  Don't use for trivial purposes. Reserve for choices that deserve
  motivation or non-obvious mechanisms that need explanation.
- **Terse but rigorous tone.** No apology paragraphs, no self-
  apologetic prose. When wrong → admit in one sentence, fix, move on.

## Methodology

- **Surgical, one thing at a time.** The plan
  `2026-05-01-aurora-dx-style-porting.md` was split into 9 phases for
  exactly this reason. Each phase touches one domain. Don't cram
  three domains into one commit.
- **Local pre-flight before push.** The user's home setup (PC + fiber)
  runs a pre-flight in 3-5 min — almost always worth spending those
  minutes to avoid 6 red CI jobs (15 min total + public CI minutes).
- **Pause for user confirmation before non-reversible actions:** every
  `git push`, `podman rmi`, `gh release`, `git reset` needs explicit
  confirmation. Don't auto-execute.
- **Fix-forward, no debt:** when an issue surfaces during a review or
  via a user question, fix it **immediately** in a separate commit
  (Conventional Commits `refactor(...)`); don't let it accumulate.
- **Skip when upstream does it better:** Phase 5 (Cockpit) is the
  canonical example — Bazzite ships Cockpit as a container quadlet,
  infinitely better than what we'd produce. Skipping is a win, not
  a forfeit.

## Quality standards

- **Verify upstream claims by reading the code**, not the comments.
  The bazzite-dx `vscode.repo gpgcheck=0` line had a decade-old
  `FIXME` that the actual F44/dnf5 code had already resolved — only
  rebuilding would have surfaced it. The pattern "read the code, run
  a quick test" is the defense.
- **No safety bypasses:** never `|| true` to hide errors, never
  `--no-verify`, never `--force`, never `rm -rf /var`. If a step
  fails it's because there's a bug — debug, don't work around.
- **Better than upstream when possible:** bazzite-mx has 17 documented
  wins over bazzite-dx (see
  [`wins-over-upstream.md`](wins-over-upstream.md)). Aspiration:
  every Phase adds ≥1 real advantage.

## Decision-making

- **Provenance citation always.** When proposing a package / pattern /
  fix, cite "from Aurora-DX line X", "from Bazzite-DX file Y", "my
  proposal based on Z". The user has caught hallucinated provenance
  multiple times; transparency = trust.
- **Explicit tradeoff.** Every proposal has tradeoffs; lay them out
  in a cost/value table + explicit recommendation ("my advice: X").
  Don't punt the decision by leaving three equivalent options.
- **Concise verdict over long debate.** When review finds an issue:
  "PROCEED to Phase X" / "FIX FIRST" / "DESIGN DISCUSSION". No
  prefatory paragraph.
- **No opinionated defaults:** if a choice is stylistic (font, theme,
  formatter), leave it to the user. AmyOS imposes choices → not our
  model. Bazzite-DX strips opinions → that's our model.

## Git / CI

- **Conventional Commits + Co-Authored-By trailer** on every Claude-
  assisted commit. Subject ≤ 70 chars, body rich with WHY +
  discoveries + pre-flight outcome.
- **SSH for `origin` remote** (persistent memory, in user's global
  `.claude` / preferences).
- **Push only after explicit confirmation** ("vai", "procedi"). Never
  push preemptively, even after a green pre-flight.
- **Commit splitting per concern:** one feature + one refactor = two
  commits, not one. Better granularity for future `git revert`.
- **Documentation commits should match paths-ignore:** `**.md`,
  `LICENSE`, `docs/**` skip CI. If a "doc" commit also touches files
  outside those patterns (e.g. `.claude/settings.json`,
  `.gitignore`), CI runs anyway — calculate it before push.

## Expected Claude behavior

- **Honest about uncertainty.** "I don't know, let me verify" beats
  a confident-but-wrong proposal.
- **Anticipate rigor questions.** The user will always ask "where did
  you get this?" and "why?". Include provenance in the first proposal.
- **Run-and-notify, no polling sleep.** For long builds/CI: use
  `run_in_background: true` and wait for the harness notification.
  No sleep loops.
- **Cleanup after verifications.** If you pre-flighted locally and CI
  is green, remove the pre-flight image (`podman rmi`) to free disk.
  Keep the Bazzite base cached (reusable for next phases).
- **Update CLAUDE.md / `.claude/docs/` proactively** when new
  conventions / gotchas / preferences emerge. Knowledge must not
  stay only in the chat transcript — this is the project's "auto
  memory".

## User-specific

- **Environment**: Bazzite (atomic Fedora) as daily driver. Knows the
  ublue ecosystem well.
- **Powerful PC + fiber at home**, local builds are cheap. When
  traveling (mobile / mobile internet), prefers CI-only. The user
  signals this explicitly.
- **GitHub username**: MatrixDJ96. Email: mattyro96@gmail.com. Repo
  `MatrixDJ96/bazzite-mx`. Knows exactly what gh CLI / cosign /
  podman / buildah do — no elementary explanations needed.
- **Appreciates explanation of choices** (insight blocks), but not
  encyclopedic paragraphs. Target: 3-5 lines per insight, max.

## Anti-patterns to avoid

- **Don't present proposals as lists without a recommendation**
  ("option A, B, C — you decide" without saying which one you
  recommend). The user wants your judgment, even if they then
  override it.
- **Don't ship in a hurry without verifying provenance.** Phase 4 v1
  had GitKraken as "IDE" — semantically wrong. A "is this actually
  correct taxonomy?" pass before commit would have caught it.
- **Don't ignore user questions by pushing forward.** When they raise
  a scope question ("do we really need this Phase?"), pause and
  answer. Don't proceed with the original plan while ignoring the
  doubt.
- **Don't use emoji** in code / commits / files (unless explicitly
  requested). Plain text and standard Markdown.
- **Don't bloat commit bodies with boilerplate.** Only relevant
  information: scope, why, discovery, pre-flight outcome, references.
