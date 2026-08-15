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

## Origin

Extracted from a worktree of the `cavu.photo` project, at commit `51b2c71`. `docs/build-log/`
carries the full development record, including the defects that only surfaced when the code first
met the real CLI.
