---
name: gauntlet-review
description: Use when the user requests Gauntlet, a peer review of a committed specification, plan, branch or pull request, or the gauntlet-dev pipeline reaches a review gate.
---

# Gauntlet review

Use **collaborative MCP by default**. This is a tool-enabled peer review of pinned
Git objects with persistent findings and evidence. It does not claim legacy
hermetic isolation. Native hosts own authentication, conversations and tool
permissions.

## Choose the route

| Request | Route |
| --- | --- |
| "Run Gauntlet", spec/plan, local branch or PR review | Collaborative MCP |
| Explicit "legacy", "hermetic" or `mode=legacy` | [LEGACY.md](LEGACY.md) |
| MCP tools missing, misconfigured, refused or unavailable | Report the gap; preserve state; do not silently fall back |

Mode is separate from scope: spec/plan, local branch and PR are all supported
collaborative scopes when their changes are committed and included in the pinned
diff. A PR URL alone does not select legacy mode. Do not claim review of dirty
worktree content or an uncommitted document.

Read [references/collaborative-review.md](references/collaborative-review.md)
before a collaborative gate. Discover the actual configured tools and their
schemas; host aliases may differ. The core exposes `open_review`, `read_review`,
`record_evidence`, `review_status` and reviewer-only `submit_review`. Author hosts
normally expose only the first four. The optional SDK peer exposes `codex_status`
and `codex_review`; a separately operated peer can instead use its own reviewer
core. Do not invent tools, impersonate the reviewer or submit your own peer
verdict from the author role.

## Essential checks

1. Check core status and, when using the SDK bridge, peer status without starting
   a model turn. Verify the operator's repository, source/target refs, private
   state and distinct participant roles match the intended review. A healthy
   empty store is not a review verdict. A `main` versus `origin/main` installation
   check is not a feature-branch review. Hosts own fetching and PR freshness.
2. Open a pinned revision using the current store version and a new operation
   key. Record exact commit IDs, returned bindings and verification evidence.
   Use the existing series for that repository/ref pair; never reset history.
3. Have the peer read the complete manifest, changed old/new bytes, relevant
   pinned context, history and evidence. It must validate page chains and digests,
   then submit complete coverage and a carry-over entry for every prior finding.
4. Inspect the canonical findings, verify each proposed fix, commit changes and
   append the next revision. Continue the owned peer thread while usable. A
   restarted or poisoned adapter requires an explicitly fresh conversation that
   rereads existing history; never silently retry uncertain model work.
5. Check **fresh** core status. Only current `peer_complete` closes the local
   gate. Stale refs, refusals, missing coverage, exhausted budgets or unresolved
   non-nit findings cannot be reported as completion.

## Publication and legacy boundaries

MCP completion, peer final text and a legacy `approve` verdict do not authorize a
GitHub approval, review comment, merge or deployment. Follow the user's specific
publication and communication authorization; keep a task-specific prohibition
on approval/merge in force. Never switch GitHub identity globally. Preserve
every original finding, failed attempt, native receipt and evidence archive.

For explicitly selected legacy mode, load `LEGACY.md` from this skill's root.
Its relative script/reference paths are rooted in this skill directory. Keep
its calibrated prerequisites, bounded harness and canonical carry-over rules;
do not import legacy state into the collaborative database. The authorization
rules above override historical instructions to automatically publish a GitHub
approval or run the full PR pipeline. If legacy calibration fails, report that
failure rather than substituting MCP without an explicit mode decision.

Present every finding in the final response, ordered by priority (`[P0]` through
`[P3]`), with file/line or section, issue and requested change. Say explicitly
when there are no findings. Report the reviewed commits, freshness, verification
limits, evidence locations and the next useful action.
