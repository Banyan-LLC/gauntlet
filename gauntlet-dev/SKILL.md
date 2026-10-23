---
name: gauntlet-dev
description: Use at task initiation for substantial features that need specification, implementation-plan and code-review gates. Not for small fixes. The user can opt out with "skip codex review".
---

# Gauntlet development pipeline

Use **collaborative MCP reviews by default**, through `gauntlet-review`. Native
hosts own conversations and permissions; the core preserves pinned revisions,
immutable findings and evidence. User instructions and project policy take
precedence. Address the user as The Human Overlord when appropriate.

## Mode selection

- An ordinary Gauntlet request selects collaborative MCP. Missing tools or an
  incompatible repository are setup failures: report the specific gap and keep
  existing history. Never silently switch modes or start the old harness.
- An explicit request for **legacy**, **hermetic** or `mode=legacy` selects
  [LEGACY.md](LEGACY.md). Read `gauntlet-review`'s mode and authorization rules
  before following that historical pipeline. Legacy state, calibrated premises,
  scripts and limits remain separate and unchanged.

## Pipeline

1. **Specify:** use the project's discovery/spec workflow for substantial work.
   Commit the spec; review its pinned Git change using `gauntlet-review`, then
   present the spec and every finding for the user's spec gate.
2. **Plan:** write and commit the implementation plan. Review its pinned change
   against the approved spec, then honor the user's plan gate. Existing approval
   of the task's spec/plan carries forward; do not restart completed gates.
3. **Build:** implement within the approved scope in a clean worktree; verify
   behavior. Use delegation only when authorized or required by an applicable
   workflow, rather than launching a fixed set of review agents for every task.
4. **Review locally:** use collaborative MCP on committed changes. Fix verified
   findings, commit, append a revision to the same review series and have the
   peer account for every original finding. Keep all failed attempts and evidence.
5. **Publish and verify:** follow the user's publication instructions. For an
   authorized PR, target `main`, publish as ready for review under the user's
   identity, and run CI. Confirm the live PR head and base against the intended
   local refs; a local MCP status cannot establish GitHub freshness. Recheck the
   exact PR head through collaborative review, reusing its existing series when
   the configured repository/ref pair is the same.
6. **Hand off:** report fresh peer status, exact commits, CI results, every
   unresolved finding and evidence locations. A fresh `peer_complete` is a local
   peer verdict, not CI success or a GitHub approval. Never approve or merge
   without the user's separate explicit authorization. A task-specific ban on
   approval or merge remains in force.

Finite budgets may end with findings open. Report that state without resetting
the review or claiming completion. Keep legacy review archives and native
conversation history even when moving a new task to the MCP route.
