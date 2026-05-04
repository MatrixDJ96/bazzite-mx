# Wins over `bazzite-dx` upstream

bazzite-mx is a personal fork that aims to be **strictly better** than
`ublue-os/bazzite-dx` upstream by adopting Aurora-DX's build patterns and
fixing concrete issues. **0 wins** at scaffold time — wins accumulate as
each domain commit lands.

## How to extend this list

When adding a new Phase, deliberately ask: **does this give us an edge
over upstream `bazzite-dx`?** If yes, document it here with:
- Commit hash that introduces it.
- The upstream behaviour we're improving on (with `file:line` reference).
- Our solution (with `file:line` reference).
- Why it matters for an end user.

Avoid soft wins (formatting, naming, "I prefer X"). Real wins:
- A bug we fix that they ship broken.
- A package they're missing that's clearly within scope.
- A supply-chain hardening they don't have.
- A maintenance reduction (zero-cost auto-update of keys, etc.).
