# `.claude/docs/` — supplementary project documentation

These files are referenced from the root `CLAUDE.md` but **not auto-loaded** by
Claude Code. Read the relevant file when a topic comes up:

| File | Read when… |
|---|---|
| [`architecture.md`](architecture.md) | Discussing build flow, repo layout, Containerfile stages, CI matrix, why a design is shaped this way. |
| [`conventions.md`](conventions.md) | Writing new bash, editing scripts, adding a third-party repo, extending smoke tests, choosing a commit message. |
| [`workflow.md`](workflow.md) | Starting a new phase, deciding when to push, deciding whether to do a code review round, handling a CI failure. |
| [`gotchas.md`](gotchas.md) | A familiar-looking error appears (silent dnf5 setopt, HEAD-rejecting CDN, paths-ignore behaviour, etc.). Always check here first. |
| [`preferences.md`](preferences.md) | Shaping a response or a plan — captures how the user wants to collaborate. |
| [`wins-over-upstream.md`](wins-over-upstream.md) | Explaining why bazzite-mx is worth the effort vs upstream `bazzite-dx`. |

Update these files **as you discover** new conventions, gotchas, or preferences
— do not let knowledge stay only in the chat transcript. Cross-reference with
`docs/superpowers/plans/2026-05-01-aurora-dx-style-porting.md` for the long-form
implementation plan.
