---
name: codex-reviewed-dev
description: Development pipeline with Codex peer-review gates. Use at TASK INITIATION for any substantial feature - the same tasks that warrant the superpowers brainstorming/spec flow - BEFORE invoking brainstorming. Not for small fixes. User opts out by saying "skip codex review".
---

# Codex-Reviewed Development Pipeline

Wraps the superpowers lifecycle (pinned: superpowers 6.0.2 — re-verify both insertion points on superpowers updates). This is user policy and takes precedence over brainstorming's "writing-plans is the only next skill" rule. Every superpowers user gate still happens, on Codex-approved documents.

**Defaults** (project AGENTS.md/CLAUDE.md may override; in-session user instructions win):
author `geoffroth` · reviewer `BanyanLLC` · round cap 10/phase · CI-fix cap 3 · model `gpt-5.6-sol` @ `xhigh` · embed budget 50,000 bytes (operational input bound; the acceptance-time usage gate on the real CLI's reported usage is the actual guarantee — see codex-review SKILL.md).

## Pipeline

1. **Spec**: superpowers brainstorming → spec committed →
   **INSERTION POINT A**: codex-review skill, doc mode, phase `spec` → approval or human flag →
   user reviews the Codex-approved spec (brainstorming's gate).
2. **Plan**: superpowers writing-plans → plan committed →
   **INSERTION POINT B**: codex-review, doc mode, phase `plan` (approved spec as TRUSTED CONTEXT — the only trusted context) →
   user plan-review gate. NEVER start implementation before it.
3. **Build**: subagent-driven development per existing conventions. No Codex involvement.
4. **PR**:
   a. Sync main; verification gates; branch `feat/…`/`fix/…`/`chore/…`; push; PR as geoffroth
      (`GH_TOKEN=$(gh auth token -u geoffroth) gh pr create …` from Git Bash).
   b. CI gate (author-owned): `GH_TOKEN=$(gh auth token -u geoffroth) gh pr checks <n> --watch`;
      fix+re-push; 3 consecutive failures → human flag. Only green builds reach review.
   c. codex-review pr mode: record `(baseOid, headSha, baseRefName, baseTipOid)` — the latter two
      are the base branch's live tip (a SEPARATE endpoint from the PR's static `baseRefOid`; see
      codex-review/SKILL.md's pr-mode-inputs section and docs/build-log/task-14-report.md).
      **Before composing the prompt, confirm the pushed head is actually live**:
      `Wait-PrHeadSynced` (lib.ps1) must return `Synced=true` for the exact commit just pushed —
      never compose or spend a round on an unsynced head. WHY: a live drill had `gh pr view`
      return the pre-push head seconds after pushing, so a round was composed against the OLD
      blob and wasted a full round of the 10-round cap re-reporting an already-fixed defect.
      prompt = metadata + exact-base diff (ALL untrusted); invoke-codex → publish-review as
      BanyanLLC. Exits 2/3 → refresh oids, re-review (a round). Exit 4 → human flag NOW. Exit 5 → retry once.
      Exit 6 → human flag NOW — the publish arguments don't match the attempt record that produced
      the round's canonical verdict (checked locally, before any `gh` call); do not blindly retry,
      re-derive the arguments from the named attempt record first (see codex-review/SKILL.md).
   d. request_changes → fix, push, green CI, confirm the new head is synced (`Wait-PrHeadSynced`,
      same requirement as (c) — this is the exact push→re-review transition the live drill's
      wasted round happened on), then a FRESH round whose ledger records each prior finding as
      addressed/disputed/outstanding; re-review the new `(baseOid, headSha, baseRefName, baseTipOid)`.
5. **Handoff**: `Test-HandoffFresh` (lib.ps1) must return Fresh — APPROVED state, commit match, head oid unchanged, AND the base ref's name/live tip unchanged (a separate, independently-checked endpoint from the PR's static base oid — see docs/build-log/task-14-report.md). Stale → re-sync, re-enter review. Then notify the user (message + push notification). **The user merges. Never merge.**

## Identity

No `gh auth switch`, ever. geoffroth token for author calls, BanyanLLC token inside publish-review — per-command/per-process only. Preflight before any push: both tokens retrievable, codex-review probe passes; miss → stop and report.

## Human flags

Stop; summarize state and sticking points; push notification. Triggers: exits 4/6/10/14, cap
reached, CI-fix cap, transient-failure retry exhausted, dismissal denied, publish-argument/
attempt-provenance mismatch (exit 6 — see codex-review/SKILL.md).

Exit 12 is NOT unconditional. Two self-serve manifest causes, both handled exactly as the
codex-review protocol says: stack-identity drift (absent, stale, or bound to a different
binary — routine after a Codex update) — re-record with `calibrate-premises.ps1`; missing or
stale **live evidence** (calibration proves the stack ACCEPTED, never LIVE-VERIFIED, and always
clears the WHOLE live-evidence object, so it cannot fix this cause on its own) — `live_evidence`
carries TWO independently-fingerprinted sub-records, `schema_gate` and `security_battery`; the
refusal message names the specific one that is missing or stale — rerun
`tests/live/live-schema-gate.ps1` for `schema_gate`, `tests/live/live-security.ps1` for
`security_battery` (run whichever the message names LAST, since a later calibration would drop
both records again). Either way, re-invoke afterward. Only a non-manifest exit 12 (harness,
token) is a human flag.
