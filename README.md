# spec-plan-review

Two reusable [Claude Code](https://claude.ai/code) skills that put an independent AI reviewer —
OpenAI Codex running `gpt-5.6-sol` at `xhigh` reasoning effort — in front of the spec, the plan,
and the finished pull request.

| | |
|---|---|
| `codex-review/` | The primitive: one bounded, hermetic review loop over a document or a PR. Usable on its own. |
| `codex-reviewed-dev/` | The orchestrator: wraps a development lifecycle so spec, plan and PR each pass a review gate. |
| `tests/` | Unit suite (no network, no GitHub) plus live batteries that exercise the real CLI. |
| `install.ps1` | Copies both skills into `~/.claude/skills/`. Refuses to install if the premise manifest is stale or absent. |
| `docs/` | The controlling design and implementation plan, plus the build log. |

## What makes it trustworthy

The reviewer runs **hermetically**: no user config, no MCP servers, no plugins, no shell, no file
access, no web. Every feature the CLI enumerates is disabled unless it is on a minimal allowlist,
so a capability added by a future CLI version is disabled automatically rather than inherited. All
review material is embedded in the prompt and delivered over stdin, and the working directory is a
single-use, unpredictably-named harness that is verified empty before every run — the reviewer has
no way to reach anything it was not handed.

A live security battery (`tests/live/live-security.ps1`) makes this claim control-verified, not
just configured: shell, web, MCP, apps, and plugins are each proven with a positive control that
fires when that one capability is enabled and stays silent under the real disable set. Two of the
CLI's remaining feature-gated classes — computer-use and skill-search — and multi-agent spawning
produced no distinguishing effect on this CLI version even when independently enabled, so those
three are configured off by the same default-deny sweep but not independently control-proven;
see `docs/design.md` and `docs/build-log/task-11-report.md`.

Everything the loop promises is **enforced rather than documented**:

- **Bounded** — 10 rounds per phase, 2 attempts per round, checked before any process starts, so a
  refused invocation launches nothing and mutates nothing.
- **Auditable across rounds** — each round is a fresh session, and continuity travels in a validated
  carry-over ledger. Omitting, duplicating, inventing or rewording a prior finding blocks the round.
- **Accepted only on measured usage** — the canonical verdict is written only if the completed run
  reported at least 25% context headroom, read from the CLI's own terminal usage event.
- **Published under the right identity** — the token's actual actor is verified before any mutation,
  publication is idempotent by marker, and a review that fails verification is dismissed, never left
  standing.

A human always merges. The skills never do.

## Requirements

Windows with PowerShell 7, the Codex CLI (desktop app or standalone), and `gh` authenticated for
the author and reviewer accounts. Run `tests/run-tests.ps1` for the offline suite; the batteries
under `tests/live/` cost real model calls and are run deliberately.

## Verification results

**Date:** 2026-08-17 · **CLI:** `0.148.0-alpha.9`, sha256 `f29f6093…c6946`, at
`%LOCALAPPDATA%\OpenAI\Codex\bin\e305f1c75d8da435\codex.exe` · **Schema:** sha256 `a036a1f6…1083a2`

| Check | Result |
|---|---|
| Offline unit suite | **553 passed, 0 failed** (composer 37, discovery 27, invoke 285, policy 15, publish 115, schema 9, state 65) |
| Live schema gate | **10 passed, 0 failed** — the shipped schema is accepted by the real API; exactly one terminal `turn.completed`; usage gate satisfied |
| Live security battery | **112 passed, 0 failed** |
| Environment minimality | child environment is exactly `CODEX_HOME` + `SystemRoot`; `SystemRoot` is required (a `CODEX_HOME`-only child cannot resolve DNS) |
| Activation checklist | **4 of 4**, each in an independent non-persistent session |
| PR-phase e2e | 4 of 4 drills pass |

**Hermeticity, per capability class.** Control-verified — each fires a positive control when
isolated, is absent under the real disable set, and collides with no other class: **shell**, **web**,
**mcp**, **apps**, **plugins**. Narrowed — configured off by the same default-deny sweep but not
independently control-provable on this CLI, after genuine repeated attempts: **computer_use**,
**skills**, **subagents**. A stronger property also holds: `code_mode_host`, denied unconditionally,
is a router-level prerequisite for shell, web, apps, computer-use and skills alike. The battery
re-ran green across a mid-development CLI upgrade (`0.147.0-alpha.6.6` → `0.148.0-alpha.9`), so the
classification is verified on the shipped binary rather than assumed to carry over.

**Prompt injection.** The safety-critical property — the reviewer is never coerced into approving —
is hard-asserted and held in every trial. The model's *narration* of the attempt is non-deterministic
(measured 1/3) and is logged, never gating. The oracle also requires the verdict to identify an
independent planted defect, so a refusal alone cannot pass, and asserts no environment disclosure.

**Activation routing** (fresh sessions): a substantial feature request selected `codex-reviewed-dev`
before brainstorming; a trivial fix correctly declined the pipeline; "skip codex review" honoured the
opt-out; and a direct request selected standalone `codex-review`.

**PR-phase e2e** — [Banyan-LLC/codex-review-e2e-20260816](https://github.com/Banyan-LLC/codex-review-e2e-20260816)
(private, archived, nothing merged). Two fixtures, deliberately distinct:

- **PR #1** — a real defect fixture. The loop ran all ten rounds and **hit the round cap without
  approving**, which is the designed escalation. Every round returned `request_changes` on genuine
  findings. The cap was not raised and no approval was manufactured. Round 8 caught a
  `ReferenceError` the author had shipped and `node --check` could not see.
- **PR #2** — a trivially-correct fixture created solely to reach the approval-only mechanics.
  Drills: **head drift** → `head advanced`; **base drift** → `base advanced`, proven against the
  exact condition that defeated the original guard (`baseRefOid` frozen while the branch tip moved);
  **idempotency** → re-publish exits 0 with no duplicate review; **transient** → exit 5 with nothing
  created, then clean recovery. Fault injection is a PATH-scoped intercepted `gh`: the proxy/env
  approach cannot work here, because the child environment is cleared to `GH_TOKEN` + `SystemRoot`.

Defects found by these gates, rather than by the unit suite, are recorded in `docs/build-log/` —
including an unreachable base-drift guard, live gates that stamped nothing while reporting green,
and a fingerprint that would have thrown on every installed-tree review.

## Origin

Extracted from a worktree of the `cavu.photo` project, at commit `51b2c71`. `docs/build-log/`
carries the full development record, including the defects that only surfaced when the code first
met the real CLI.
