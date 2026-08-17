# Gauntlet

Gauntlet provides two reusable [Claude Code](https://claude.ai/code) skills that ask
OpenAI Codex to act as an independent reviewer:

| Skill | Use it for |
|---|---|
| `gauntlet-review` | A bounded review loop over one specification, implementation plan, or pull request. |
| `gauntlet-dev` | A complete development workflow with Codex review gates after the spec, plan, and pull request. |

The skills are developed and verified in this repository, but they are not limited to this
repository. `install.ps1` installs them in your user-level Claude Code skills directory, after
which a fresh Claude Code session can use them from any project checkout on the same machine.

Codex reviews; it never edits the reviewed project and never merges a pull request. A human
remains responsible for accepting recommendations and merging.

## Choose a workflow

Use `gauntlet-dev` for a substantial feature that should go through discovery, a written
specification, an implementation plan, implementation, and pull-request review. It integrates
with the Superpowers workflow.

Use `gauntlet-review` directly when you already have an artifact to review, for example:

- a specification or plan in Markdown;
- an existing pull request;
- a one-off adversarial review outside the full development pipeline.

Small fixes do not automatically enter the full pipeline. A user can also opt out for a task by
saying `skip codex review`.

## Requirements

### All review modes

- Windows and PowerShell 7 (`pwsh`).
- Claude Code.
- OpenAI Codex CLI with access to `gpt-5.6-sol` and an authenticated Codex session.
- Git.
- Permission to clone this private repository.

Confirm the local tools before installing:

```powershell
pwsh --version
claude --version
codex --version
codex login status
git --version
```

The full `gauntlet-dev` pipeline also expects the Superpowers Claude Code plugin. This
release was verified with Superpowers `6.0.2`; re-check the two insertion points described in
[`gauntlet-dev/SKILL.md`](gauntlet-dev/SKILL.md) after upgrading Superpowers.

### Pull-request publication

Document review does not require GitHub authentication. Publishing a formal GitHub PR review
also requires:

- GitHub CLI (`gh`);
- an authenticated PR-author account;
- a separate authenticated reviewer account, because GitHub does not allow an author to approve
  their own pull request;
- a repository in which the reviewer account can submit or dismiss reviews.

Authenticate both identities without globally switching between them:

```powershell
gh auth login
gh auth status
gh auth token -u <author-login> | Out-Null
gh auth token -u <reviewer-login> | Out-Null
```

The shipped project defaults are `geoffroth` for the author and `BanyanLLC` for the reviewer.
Other users should override those names in their project-level `CLAUDE.md` or `AGENTS.md` and
tell Claude to pass `-Reviewer <reviewer-login>` to `publish-review.ps1`. Do not rely on the
script's `BanyanLLC` default outside the Banyan environment.

For example, add a project instruction like this:

```markdown
## Codex-reviewed development identities

- GitHub PR author: `<author-login>`
- GitHub review publisher: `<reviewer-login>`
- Pass `-Reviewer <reviewer-login>` whenever invoking `publish-review.ps1`.
- Never switch the global `gh` account; resolve each token for the individual command.
```

## Install

Installation is deliberately fail-closed. A fresh clone does not contain `premises.json`, because
that file is evidence about the exact Codex binary and local reviewer stack on one machine. You
must generate and verify it locally before the installer will copy anything.

### 1. Clone the development repository

```powershell
git clone git@github.com:Banyan-LLC/gauntlet.git
Set-Location gauntlet
```

You can keep this checkout anywhere. Reviews run against whichever target repository Claude Code
is currently working in; the skills do not require target projects to live inside this checkout.

### 2. Run the offline tests

```powershell
pwsh -File .\tests\run-tests.ps1
```

The offline suite does not call GitHub or make model requests.

### 3. Bind the installation to the local reviewer stack

Run these commands in this exact order:

```powershell
pwsh -File .\gauntlet-review\scripts\calibrate-premises.ps1
pwsh -File .\tests\live\live-schema-gate.ps1
pwsh -File .\tests\live\live-security.ps1
```

Calibration verifies the selected CLI, schema, account-level Codex `AGENTS.md`, and invocation
profile. It makes no model request. The two live gates then prove that the real API accepts the
schema and that the reviewer remains hermetic on the selected CLI. They make real model calls;
the security battery takes several minutes and consumes model usage.

Always run calibration first. Calibration intentionally clears all prior live-evidence stamps,
so running it after either live gate makes that gate stale again.

### 4. Install the skills

```powershell
pwsh -File .\install.ps1
```

The installer:

1. refuses to continue unless the local manifest and both live-evidence records are current;
2. copies `gauntlet-review` and `gauntlet-dev` to
   `%USERPROFILE%\.claude\skills\`;
3. adds a short activation rule to `%USERPROFILE%\.claude\CLAUDE.md` if it is not already
   present.

Start a new Claude Code session after installation so skill discovery runs from a clean session.

### 5. Check activation

From a target project, try these prompts in separate fresh Claude Code sessions:

| Prompt | Expected routing |
|---|---|
| `Add a comprehensive audit-log subsystem to the admin app` | `gauntlet-dev`, then Superpowers brainstorming |
| `Fix the typo in the footer` | No reviewed-development pipeline |
| `Add audit logs — skip codex review` | Superpowers flow without Codex gates |
| `Have Codex review docs/foo.md` | Standalone `gauntlet-review` |

## Use from another repository

Open Claude Code in the repository that contains the work. The globally installed skills resolve
the target repository from that session; you do not copy this repository into each project.

### Run the full reviewed-development pipeline

Ask for a substantial feature normally:

```text
Add a comprehensive audit-log subsystem to the admin app.
```

Claude should select `gauntlet-dev` before brainstorming. The workflow is:

1. brainstorm and write a specification;
2. commit the specification and obtain Codex approval;
3. write and commit the implementation plan and obtain Codex approval;
4. implement and verify the change;
5. open a green pull request and run the Codex PR-review loop;
6. hand the approved, current pull request to the human who will merge it.

The user gates from Superpowers remain in place. Codex approval never substitutes for user
approval.

To bypass the Codex gates for one task, say so explicitly:

```text
Add audit logs — skip codex review.
```

### Review one document

Commit the document, then ask Claude Code:

```text
Have Codex review docs/design.md.
```

Claude invokes `gauntlet-review` in `doc` mode. If Codex requests changes, Claude revises the
document with judgment, commits it, and starts a fresh round with a validated carry-over ledger.
The loop stops on approval or a human flag.

Document-review state is committed beside the project documentation under:

```text
docs/superpowers/reviews/<date>-<topic>/<spec-or-plan>/
```

### Review one pull request

The pull request must have green CI and the pushed head must be visible through GitHub before a
round is composed. Ask Claude Code, for example:

```text
Have Codex review PR #123 in Banyan-LLC/example-repo.
```

Claude captures the exact base, live base-branch tip, and head commit; embeds the PR metadata and
diff as untrusted review material; invokes the hermetic reviewer; and publishes the normalized
verdict under the configured reviewer identity.

PR-review state lives outside the committed project tree:

```text
<git-common-dir>/info/gauntlet-review/<owner>-<repo>/pr-<number>/
```

Publication is idempotent. Before handoff, the workflow re-checks the PR state, head, live base
tip, reviewer identity, marker, and CI. If the reviewed commit or base has moved, the stale review
is retired and the loop must review the new context.

## What to expect during a review

- Each phase is capped at 10 rounds.
- A failed attempt can be retried once; attempts and verdicts are immutable artifacts.
- Every round is a fresh Codex session. Prior findings are carried forward through a validated
  ledger, so an objection cannot silently disappear or be reworded.
- `approve` with an important or blocking recommendation is normalized to `request_changes`.
- Oversized inputs, exhausted caps, invalid provenance, identity failures, and unresolved
  environment failures stop for human intervention.
- The tooling never truncates review material to force it through a budget.
- The tooling never merges.

The most useful exit codes when diagnosing a stopped run are:

| Exit | Meaning | Next action |
|---|---|---|
| `0` | Successful round or publication | Read the canonical verdict or continue the workflow |
| `10` | Input/usage budget exceeded | Human flag; reduce artifact scope deliberately |
| `11` | Failed process, event stream, or verdict | Retry the same round once |
| `12` | Reviewer environment or manifest invalid | Follow the specific error; refresh stack evidence when named |
| `13` | Pinned Codex binary changed | Re-run the same round with `-AcceptNewBinary` |
| `14` | Round/attempt cap or completed-round replay | Stop and escalate |
| `16` | Carry-over ledger missing or invalid | Rebuild it from canonical prior verdicts; do not omit entries |

PR publication additionally uses `2`/`3` for review-context drift, `4` for an immediate human
flag, `5` for one retryable transient GitHub failure, and `6` for locally detected verdict/
provenance mismatch. See [`gauntlet-review/SKILL.md`](gauntlet-review/SKILL.md) for the full protocol.

## Update or reinstall

After pulling changes to this repository, run the offline suite and `install.ps1` again. If the
installer reports stale stack identity or live evidence—commonly after a Codex CLI, schema,
invocation-policy, or account-level `~/.codex/AGENTS.md` change—repeat the complete sequence:

```powershell
pwsh -File .\gauntlet-review\scripts\calibrate-premises.ps1
pwsh -File .\tests\live\live-schema-gate.ps1
pwsh -File .\tests\live\live-security.ps1
pwsh -File .\install.ps1
```

Do not edit or copy `premises.json` by hand. It is machine-specific authorization evidence, not
configuration.

## Repository layout

| Path | Purpose |
|---|---|
| `gauntlet-review/` | Primitive skill, schemas, and PowerShell entry points |
| `gauntlet-dev/` | Full-development orchestrator skill |
| `tests/` | Offline unit suite and deliberate live gates |
| `install.ps1` | Fail-closed user-level installer |
| `docs/design.md` | Controlling security and workflow design |
| `docs/implementation-plan.md` | Implementation plan and contracts |
| `docs/build-log/` | Build record and defects found against the real CLI |

## Security model

The reviewer runs hermetically: no target-repository file access, user config, MCP servers,
plugins, shell, or web. Review material is embedded in the prompt and sent over stdin. The
working directory is a single-use, unpredictably named, empty harness outside every repository.
Every CLI feature is disabled unless explicitly allowlisted, so a feature introduced by a future
CLI version is denied by default.

The live security battery independently control-verifies shell, web, MCP, apps, and plugins.
Computer-use, skill-search, and subagent spawning were configured off but did not produce an
independently observable positive signal on the verified CLI, so the guarantee is deliberately
narrower for those three classes. See [`docs/design.md`](docs/design.md) for the exact claim.

All reviewed material—including PR titles, descriptions, diffs, and check summaries—is treated
as untrusted. Only explicitly approved controlling documents enter trusted context.

## Verification results

**Date:** 2026-08-17 · **CLI:** `0.148.0-alpha.9`, sha256 `f29f6093…c6946`, at
`%LOCALAPPDATA%\OpenAI\Codex\bin\e305f1c75d8da435\codex.exe` · **Schema:** sha256 `a036a1f6…1083a2`

| Check | Result |
|---|---|
| Offline unit suite | **602 passed, 0 failed** (composer 37, discovery 27, harness 39, invoke 285, policy 15, publish 125, schema 9, state 65) |
| Live schema gate | **10 passed, 0 failed** — shipped schema accepted; exactly one terminal `turn.completed`; usage gate satisfied |
| Live security battery | **112 passed, 0 failed** |
| Environment minimality | Child environment exactly `CODEX_HOME` + `SystemRoot`; `SystemRoot` is required for DNS |
| Activation checklist | **4 of 4**, each in an independent non-persistent session |
| PR-phase end to end | **4 of 4** drills passed |

The live battery control-verified **shell**, **web**, **MCP**, **apps**, and **plugins**. It
configured off but narrowed the independent claim for **computer-use**, **skills**, and
**subagents**. It also established that denied `code_mode_host` is a router-level prerequisite
for shell, web, apps, computer-use, and skills.

Prompt-injection tests hard-assert that hostile material cannot coerce an approval and require the
reviewer to identify an independent planted defect. Narration of the injection attempt is
non-deterministic and deliberately non-gating.

The end-to-end fixture is the private, archived
[`Banyan-LLC/gauntlet-review-e2e-20260816`](https://github.com/Banyan-LLC/gauntlet-review-e2e-20260816)
repository. PR #1 exercised genuine findings and correctly escalated at the round cap without a
manufactured approval. PR #2 was a deliberately trivial fixture used to reach approval-only
head-drift, base-drift, idempotency, and transient-recovery drills. Nothing was merged.

Defects found by the live gates rather than the unit suite—including a previously unreachable
base-drift guard, evidence gates that reported green without stamping evidence, and an
installed-tree fingerprint failure—are documented in [`docs/build-log/`](docs/build-log/).
