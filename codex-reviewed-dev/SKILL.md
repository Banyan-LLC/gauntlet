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
   c. codex-review pr mode: record `(baseOid, headSha)`; prompt = metadata + exact-base diff (ALL untrusted);
      invoke-codex → publish-review as BanyanLLC. Exits 2/3 → refresh oids, re-review (a round). Exit 4 → human flag NOW. Exit 5 → retry once.
   d. request_changes → fix, push, green CI, then a FRESH round whose ledger records each prior finding as addressed/disputed/outstanding; re-review the new `(baseOid, headSha)`.
5. **Handoff**: `Test-HandoffFresh` (lib.ps1) must return Fresh — APPROVED state, commit match, both current oids equal the reviewed pair. Stale → re-sync, re-enter review. Then notify the user (message + push notification). **The user merges. Never merge.**

## Identity

No `gh auth switch`, ever. geoffroth token for author calls, BanyanLLC token inside publish-review — per-command/per-process only. Preflight before any push: both tokens retrievable, codex-review probe passes; miss → stop and report.

## Human flags

Stop; summarize state and sticking points; push notification. Triggers: exits 4/10/14, cap
reached, CI-fix cap, transient-failure retry exhausted, dismissal denied.

Exit 12 is NOT unconditional. Two self-serve manifest causes, both handled exactly as the
codex-review protocol says: stack-identity drift (absent, stale, or bound to a different
binary — routine after a Codex update) — re-record with `calibrate-premises.ps1`; missing or
stale **live evidence** (calibration proves the stack ACCEPTED, never LIVE-VERIFIED, and always
clears any existing live-evidence record, so it cannot fix this cause on its own) — rerun
`tests/live/live-schema-gate.ps1` (run this one LAST, since a later calibration would drop the
evidence again). Either way, re-invoke afterward. Only a non-manifest exit 12 (harness, token)
is a human flag.
