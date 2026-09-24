---
name: gauntlet-dev
description: Gauntlet: a development pipeline with Codex peer-review gates. Use at TASK INITIATION for any substantial feature - the same tasks that warrant the superpowers brainstorming/spec flow - BEFORE invoking brainstorming. Not for small fixes. User opts out by saying "skip codex review".
---

# Gauntlet Development Pipeline

Wraps the superpowers lifecycle (pinned: superpowers 6.0.2 — re-verify both insertion points on superpowers updates). This is user policy and takes precedence over brainstorming's "writing-plans is the only next skill" rule. Every superpowers user gate still happens, on Codex-approved documents.

**Defaults** (project AGENTS.md/CLAUDE.md may override; in-session user instructions win):
author `geoffroth` · reviewer `BanyanLLC` · round cap 10/phase · CI-fix cap 3 · model `gpt-6-sol` @ `xhigh` · embed budget 100,000 bytes default, raised to 500,000 AUTONOMOUSLY (no user prompt) as needed; a prompt over 500,000 bytes is a human flag (operational input bound; the acceptance-time usage gate on the real CLI's reported usage is the actual guarantee, see gauntlet-review SKILL.md).

## Pipeline

1. **Spec**: superpowers brainstorming → spec committed →
   **INSERTION POINT A**: pre-review hardening (below), then gauntlet-review skill, doc mode, phase `spec` → approval, cut-short offer, or human flag →
   user reviews the Codex-approved spec (brainstorming's gate). (Spec/plan cut-short applies — see below.)
2. **Plan**: superpowers writing-plans → plan committed →
   **INSERTION POINT B**: pre-review hardening (below), then gauntlet-review, doc mode, phase `plan` (approved spec as TRUSTED CONTEXT — the only trusted context) →
   user plan-review gate. NEVER start implementation before it. (Spec/plan cut-short applies — see below.)
3. **Build**: subagent-driven development per existing conventions. No Codex involvement.
4. **Review & PR** — at the review transition (implementation complete), **OFFER the user both
   paths; never pick silently**. The goal is to spend CI runs and PR review rounds only on
   already-hardened code — each PR round costs a push + a CI run + a live review round.
   - **A. Local-branch review (recommended for iteration; no CI/PR churn):** gauntlet-review
     **local** mode — `-BaseOid $(git merge-base main HEAD)`, `-HeadSha $(git rev-parse HEAD)` —
     pre-review hardening (below), then the bounded loop, iterating fixes **locally** to the
     terminal bar with NO push/PR/CI/publish between rounds. When it clears, run the PR mechanics
     (a–d) **once** — already-clean, it should converge in a single pr round. Local mode is a
     best-effort pre-check on your own repo; the single pr-mode round in (a–d) is the AUTHORITATIVE
     gate and the backstop for anything local hermeticity missed, so it is never skipped.
   - **B. PR-per-round (full flow):** the PR mechanics (a–d) from the start — each fix is a new
     push + CI run + pr round. Choose when you specifically want every round on the PR with CI.

   PR mechanics (used once after path A, or each round in path B):
   a. Sync main; verification gates; branch `feat/…`/`fix/…`/`chore/…`; push; PR as geoffroth
      (`GH_TOKEN=$(gh auth token -u geoffroth) gh pr create …` from Git Bash).
   b. CI gate (author-owned): `GH_TOKEN=$(gh auth token -u geoffroth) gh pr checks <n> --watch`;
      fix+re-push; 3 consecutive failures → human flag. Only green builds reach review.
   c. Pre-review hardening (below), THEN gauntlet-review pr mode: record `(baseOid, headSha, baseRefName, baseTipOid)` — the latter two
      are the base branch's live tip (a SEPARATE endpoint from the PR's static `baseRefOid`; see
      gauntlet-review/SKILL.md's pr-mode-inputs section and docs/build-log/task-14-report.md).
      **Before composing the prompt, confirm the pushed head is actually live**:
      `Wait-PrHeadSynced` (lib.ps1) must return `Synced=true` for the exact commit just pushed —
      never compose or spend a round on an unsynced head. WHY: a live drill had `gh pr view`
      return the pre-push head seconds after pushing, so a round was composed against the OLD
      blob and wasted a full round of the 10-round cap re-reporting an already-fixed defect.
      prompt = metadata + exact-base diff (ALL untrusted); invoke-codex → publish-review as
      BanyanLLC. Exits 2/3 → refresh oids, re-review (a round). Exit 4 → human flag NOW. Exit 5 → retry once.
      Exit 6 → human flag NOW — the publish arguments don't match the attempt record that produced
      the round's canonical verdict (checked locally, before any `gh` call); do not blindly retry,
      re-derive the arguments from the named attempt record first (see gauntlet-review/SKILL.md).
   d. request_changes → fix, push, green CI, confirm the new head is synced (`Wait-PrHeadSynced`,
      same requirement as (c) — this is the exact push→re-review transition the live drill's
      wasted round happened on), then a FRESH round whose ledger records each prior finding as
      addressed/disputed/outstanding; re-review the new `(baseOid, headSha, baseRefName, baseTipOid)`.
**Spec/plan cut-short (points A & B).** The doc-mode review keeps running while any **blocking**
finding remains. The moment a round returns **no blocking or important recommendations** (only
**nit** recommendations, if anything), OFFER the user to cut the loop short — conclude and go to
their review gate, no formal `approve` verdict required — rather than spend further live rounds
chasing a clean approve. The existing no-blocking floor still lets them proceed with important
recommendations open if they choose; this offer is the cleaner "nothing important left" stop. It
is an OFFER, not automatic — the user may also push on to a formal approve.

5. **Handoff**: `Test-HandoffFresh` (lib.ps1) must return Fresh — APPROVED state, commit match, head oid unchanged, AND the base ref's name/live tip unchanged (a separate, independently-checked endpoint from the PR's static base oid — see docs/build-log/task-14-report.md). Stale → re-sync, re-enter review; if the reason is specifically head or base drift, first call `Revoke-SupersededReview` (lib.ps1) to retire the stale tool-owned approval — see gauntlet-review/SKILL.md's Handoff section for the exact contract and its three safety preconditions. `Test-HandoffFresh` itself never mutates. Then notify the user (message + push notification). **The user merges. Never merge.**

## Pre-review hardening (before EVERY Codex gate — points A, B, and 4c)

Codex rounds are live and paid; local subagents are cheap. Before spending a round, pre-harden the
artifact with the SAME lenses the reviewer applies, so the FIRST submission already clears most of
them. WHY: PR #2 took **7 rounds** mostly because instance-level fixes revealed a defect *class* a
layer at a time (one class drew a new finding in six of the seven rounds) — the reviewer was not
withholding, the depth was emergent. Full rationale, evidence, and the lens list: `gauntlet-review/references/review-lenses.md`.

- Dispatch **one subagent per lens** (fail-closed; resource bounds & lifecycle; path/filesystem
  safety; cross-platform parity; typed/structured errors; spec conformance), with per-mode inputs:
  - **spec (point A):** the artifact under review IS the spec and there is NO approved controlling
    spec yet — never feed the spec back as its own controlling context. Agents review it against
    the lenses + sound engineering/security principles + any SEPARATE, already-user-approved
    requirements doc if one exists (the spec-conformance lens is N/A here).
  - **plan (point B) / PR (4c):** the plan (doc) or the changed files (pr), each given the APPROVED
    spec as the conformance baseline.
  Because the agents have file access (the hermetic reviewer does not), THEY do the repository-wide
  expansion the reviewer cannot: every unchanged sibling instance, every call site, the whole
  subsystem a change touches.
- Aggregate; **fix by CLASS, not instance** — every sibling occurrence, every call site, every
  platform, in one pass; then re-run tests + a regression scan (a fix you have not exercised can
  itself cost a round, as PR #2's round-6 regression did).
- THEN invoke gauntlet-review. Compose its prompt from the current template — the THOROUGHNESS
  MANDATE is REQUIRED. TRUSTED CONTEXT stays approved-controlling-documents-only (invariant 5):
  the security invariants and production platform must be declared IN the approved spec, never
  asserted free-form in the prompt; record any accepted/deferred limitation ONLY as a `disputed`
  entry with a `reason` in the validated carry-over ledger — never as trusted context.
- This does NOT replace or soften the Codex gate; it raises the floor so the gate converges in
  ~2–3 rounds. Skip only for a genuinely trivial diff.

## Identity

No `gh auth switch`, ever. geoffroth token for author calls, BanyanLLC token inside publish-review — per-command/per-process only. Preflight before any push: both tokens retrievable, gauntlet-review probe passes; miss → stop and report.

## Human flags

Stop; summarize state and sticking points; push notification. Triggers: exits 4/6/14, cap
reached, CI-fix cap, transient-failure retry exhausted, dismissal denied, publish-argument/
attempt-provenance mismatch (exit 6 — see gauntlet-review/SKILL.md). **Exit 10 is NOT automatically
a human flag:** a byte-preflight overflow is retryable — raise `-BudgetBytes` up to 500,000
AUTONOMOUSLY and re-invoke; only a prompt over 500,000 bytes, or the acceptance-time usage-gate
exit 10 (real tokens <25% headroom), is a human flag.

Exit 12 is NOT unconditional. Two self-serve manifest causes, both handled exactly as the
gauntlet-review protocol says: stack-identity drift (absent, stale, or bound to a different
binary — routine after a Codex update) — re-record with `calibrate-premises.ps1`; missing or
stale **live evidence** (calibration proves the stack ACCEPTED, never LIVE-VERIFIED, and always
clears the WHOLE live-evidence object, so it cannot fix this cause on its own) — `live_evidence`
carries TWO independently-fingerprinted sub-records, `schema_gate` and `security_battery`; the
refusal message names the specific one that is missing or stale — rerun
`tests/live/live-schema-gate.ps1` for `schema_gate`, `tests/live/live-security.ps1` for
`security_battery` (run whichever the message names LAST, since a later calibration would drop
both records again). Either way, re-invoke afterward. Only a non-manifest exit 12 (harness,
token) is a human flag.
