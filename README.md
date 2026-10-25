# Gauntlet

The [collaborative MCP core](docs/collaborative-mcp.md) is the default route in
the Gauntlet skills. It stores pinned Git reviews, findings and evidence while
native hosts manage conversations. Legacy hermetic mode remains an explicit
option: request `legacy`, `hermetic` or `mode=legacy` and follow the preserved
`LEGACY.md` in each skill. Missing MCP setup does not silently select legacy.
The live Claude-to-Codex conversation
walkthrough passed through the official Python SDK and app server. The setup
guide records the proof, assurance limits and separate review/CI requirements.

Historical review metadata can additionally use `-CompactReviewMetadata` with
`-CompactAddedFiles` in local or PR mode. Complete added review JSON/JSONL files
retain every unique raw string token and every other character; duplicate tokens
use explicit backward references. The certified decoder reconstructs each full
original section exactly and verifies full Git identities and ordered coverage.
Code, tests and the live carry-over ledger never enter that metadata table. Both unchanged 1 MiB
request limits and every existing review/capacity gate still apply. See
`gauntlet-review/LEGACY.md` for legacy framing and bounds.

`-CompactIndentation` additionally represents recoverable leading indentation
in verified complete added source files under `src/`. Each four initial spaces
uses one transport tab in an `INDENT` frame. The decoder restores every original
character and line, including whitespace in raw strings. Files with literal
leading tabs fall back unchanged. All other source/test text remains directly
readable; history, limits and publication gates are preserved. This option also
requires `-CompactAddedFiles` and is available in local and PR modes.

`-CompactRepeatedLines` is a separate opt-in for complete added regular source
files under `src/`, requiring `-CompactAddedFiles` in local or PR mode. It may be
combined with either indentation or historical metadata framing. A visible
`~N=TEXT` labels the first literal source core; `~N~` reuses that exact core with
the current row's leading spaces/tabs. Full original files and unified sections
reconstruct exactly, including raw strings, trailing whitespace and blank rows.
Reserved literal marker rows cause whole-file fallback. Existing-file hunks,
other formats, historical metadata rules and the live ledger are unchanged.

The source dictionary is limited to 65536 entries and 4194304 UTF-16 units.
Decoded source bodies remain limited to 1048576 units, and total reconstructed
diff to 4194304 units. Bounds are checked before appending. Each encoded frame
must strictly shorten its prior representation; disabled options preserve the
old wire format. Both complete request caps and all freshness/capacity gates
remain unchanged. The additional protocol hash is bound in attempt metadata.

`-CompactSourceFrames` optionally wraps eligible `INDENT`/`INDENT_LINES`
frames after the existing source-line pass. It requires both `-CompactAddedFiles`
and `-CompactIndentation`, in local or PR mode. F/FL encode common tab-indentation
counts and the repeated regular-file mode/index prefix once in the protocol.
They reconstruct the actual `0000000..7hex` index spelling exactly; full HEAD
blob/mode/base-absence proof remains unchanged. Other index spellings, literal
leading tabs and reserved source prefixes keep legacy framing. All prior
protocols, defaults, history and limits remain unchanged. The separate source
frame protocol is included in the prompt and fingerprinted in attempt metadata.

`-CompactSourceWords` optionally wraps complete F/FL source frames with a closed
per-file ASCII word dictionary. It requires `-CompactAddedFiles`,
`-CompactIndentation` and `-CompactSourceFrames`, in local or PR mode. Canonical
`@N` references expand before the older frame/line layers; literal marker collisions
retain the entire previous frame. Words and source-line cores share the existing
65536-entry / 4194304-unit dictionary limits. Both byte and scalar prompt caps,
source identities, history, defaults and older protocol text remain unchanged.
Its separate protocol and immutable hash are included in each opted-in request.

### Verified duplicate controlling-spec references (local mode, opt-in)

`invoke-codex.ps1 -VerifiedReferenceFile <json>` can represent one complete added
spec body by reference to its identical complete body already embedded in the
approved trusted context. It does not summarize or remove unique material.
This option is local-mode only and requires an explicit approved manifest:

```json
{
  "version": 1,
  "base_oid": "<full original base commit>",
  "head_sha": "<full finished head commit>",
  "entries": [{
    "path": "docs/superpowers/specs/<approved-spec>.md",
    "blob": "<full approved Git blob SHA-1>",
    "normalized_sha256": "<SHA-256 of complete UTF-8 LF body>"
  }]
}
```

The wrapper verifies that the path is absent at the base and bound to that blob
at the head; the diff is one complete added-file hunk; its reconstructed bytes
hash to the blob and approved SHA-256; and the complete body occurs exactly once
after the trusted-context boundary. It preserves the file headers, mode, index
and hunk header, and tells the reviewer to review the embedded body as both
control and added artifact. Every other diff section remains identical after
CRLF-to-LF normalization. Standalone CRs are rejected. Carry-over content and
the preamble retain every line, with only CRLF normalization. Existing round,
attempt, binary, harness and immutable-verdict rules still apply.

Immutable attempt metadata includes the original and rendered diff hashes,
manifest hash, original preamble hash, every section's header/hunks and original
and rendered hashes, reference identity, and the final payload hash. Invalid
references refuse before CLI discovery or attempt allocation. The existing
byte/character limits and usage gate cannot be overridden by this option.

With no bound capacity profile, this opt-in route probes both the pinned CLI's
refreshed catalog and its bundled catalog. The bundled probe uses a unique empty
CODEX_HOME without credential copies or ambient user configuration. Both must
identify the pinned model and agree on context window and effective percentage;
unavailable/malformed evidence or disagreement refuses with exit 12. This is
deliberately conservative: catalogs are capacity evidence, not a token count or
proof that the actual request will fit. Existing modes without the option retain
their prior usage policy.

On agreement the acceptance ceiling is the smaller of the existing 659,500 and
`floor(0.75 * floor(context_window * effective_percent / 100)) - 128000`.
The completed request's own input-token accounting must meet it before any
canonical verdict is accepted. The output reserve and 25% headroom are unchanged.

The user-approved bound profile (2026-10-14) resolves that ambiguity explicitly.
Machine-local `gauntlet-review/capacity-profile.json` identifies a frozen unchanged
account catalog by absolute path and SHA-256. Its model entry retains default
500,000, maximum 872,000 and 95% effective capacity. Every sealed invocation adds
`-c model_catalog_json="<snapshot>" -c model_context_window=872000`. Both arguments,
the snapshot hash and descriptor hash are bound into the full invocation audit
and certification profile. No catalog limit is invented or raised.

`tests/live/live-context-capacity.ps1` runs a small controlled fixture under the
exact sealed profile and records the runtime telemetry's
`model_context_window_effective=828400`, separately from the requested 872,000.
Machine-local `capacity-runtime-proof.json` binds the replacement executable,
catalog, invocation profile, fixture/library producer hashes, invocation audit
and sanitized diagnostic receipt. Changed/missing proof or catalog refuses
certification and invocation. Profile, proof and catalog read leases prevent
rewriting those files during Windows model execution; hashes are rechecked.

The resulting acceptance ceiling is `floor(828400 * .75) - 128000 = 493300`
input tokens. The output reserve and 25% headroom are unchanged. Request byte and
character caps remain independent, and the completed request's own exact input
usage must satisfy this ceiling before a canonical verdict can be accepted.
The actual complete prompt's token count is not inferred from its byte length.
The new CLI/profile/catalog must pass calibration and both live gates before a
coordinated install. The coordinator owns those shared operations.

Gauntlet provides two reusable [Claude Code](https://claude.ai/code) skills that ask
OpenAI Codex to act as an independent reviewer:

| Skill | Use it for |
|---|---|
| `gauntlet-review` | A bounded review loop over one specification, implementation plan, or pull request. |
| `gauntlet-dev` | A complete development workflow with Codex review gates after the spec, plan, and pull request. |

The skills are developed and verified in this repository, but they are not limited to this
repository. The setup in [collaborative-mcp.md](docs/collaborative-mcp.md) is required
for the default MCP route; once its venv exists, `install.ps1` registers the two servers
with Claude Code once, at user scope, through a launcher that binds each session to the
checkout and branch it starts in ([Global registration](docs/collaborative-mcp.md#global-registration)).
Copy each skill's `SKILL.md`, `LEGACY.md` and referenced
resources together into the host's skill directory (`~/.claude/skills` for Claude,
`~/.agents/skills` for Codex). Back up existing files first and preserve runtime
calibration files and all review state. Start a fresh host session for updated
skill discovery; reloading a skill alone does not change fixed MCP refs/roles.

The remaining installation, calibration and harness instructions below describe
the **explicit legacy route**. `install.ps1` retains its legacy stack gates and
installs the skills in your user-level Claude Code skills directory, after
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
- OpenAI Codex CLI with access to `gpt-6.1-sol` and an authenticated Codex session.
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

Before calibration or either live gate, provide an existing trusted account-level Codex
`AGENTS.md` at `%USERPROFILE%\.codex\AGENTS.md`. Both live gates refuse certification if
this file is absent. If you intentionally use no account instructions, an empty trusted file
is an explicit operator setup choice. These commands never create or fabricate that file.

The security battery prepares temporary credential copies and requires explicit authorization
to clean up its owned security tree for the actual live invocation. Only after authorizing that
invocation and its cleanup, run these commands in this exact order. The
`-AllowOwnedSecurityTreeCleanup` switch records that opt-in; omitting it refuses startup.
The security battery also requires `-FailedControlDiagnosticsRoot`, an existing regular directory
on a local fixed drive, outside the credential tree. It creates a fresh `failed-controls-<guid>`
child there with access restricted to the current Windows user. Select an artifact location you
intend to retain before starting any live call.

The computer-use positive control requests one read-only screenshot or screen-state call.
Obtain any required screen-access authorization before running it. It forbids clicks, typing,
navigation and application launches, and asks the model not to transcribe screen contents.
Native dispatch logs contain only server/tool names and event type, never arguments or images.

```powershell
pwsh -File .\gauntlet-review\scripts\calibrate-premises.ps1
pwsh -File .\tests\live\live-schema-gate.ps1
$diagnosticsRoot = Join-Path $env:LOCALAPPDATA 'gauntlet-review\diagnostics'
New-Item -ItemType Directory -Path $diagnosticsRoot -Force | Out-Null
pwsh -File .\tests\live\live-security.ps1 -AllowOwnedSecurityTreeCleanup -FailedControlDiagnosticsRoot $diagnosticsRoot
```

Failed positive controls retain one JSON record each, before credential-tree cleanup. Records
include the executable, argv as an array, process outcome, event/model output and stderr. Known
auth values (including common JSON, URL and Base64 encodings) and bearer credentials are redacted.
Percent octets decode regardless of hexadecimal case, including partial escapes, unreserved
characters and UTF-8 runs. Decoded credential matches map back to original source spans so
adjacent benign text keeps its spelling. Nested percent, JSON and Base64 encodings share the
same depth, candidate, decoded-byte and work limits; benign percent text remains unchanged.
Nested inspection receives the intact decoded token before any redaction. Direct-match
comparison preserves adjacent text without masking an encoded prefix that could hide a second credential.
Bounded Base64 and Base64URL decoding also checks recovered text and credentials inside parsed
JSON strings and property names. It handles missing padding, key/value delimiters, MIME line folding, JSON
reserialization, Unicode escapes, serialized inner JSON and both UTF-16 byte orders, including
non-ASCII prefixes. Serialized inner JSON consumes the same encoding depth and work budgets.
Raw JSON and JSON-lines inspect escaped string tokens in their original source positions;
sensitive values or property names are redacted while event boundaries and unrelated fields
remain exact. Benign raw JSON remains unchanged. Trusted raw JSON invocation content follows
the same credential checks and refuses before writing when a match or inspection limit occurs.
Bare JSON escape content, including literal escape text inside native event strings, receives
bounded recursive inspection of all standard escapes, including escaped solidus and Unicode
surrogate pairs. Consecutive escape runs decode together; ordinary Windows path text remains
literal unless transformed content proves sensitive. Valid quoted regions and known redaction spans are masked
before this check so event structure stays intact and one secret cannot hide another.
Incomplete or invalid quoted content becomes `[redacted: diagnostic scan incomplete]` rather
than retaining a possibly recoverable fragment. Trusted invocation refuses that record.
Exact-value and encoded-content redactions are combined as spans of the original text,
so one replacement cannot hide another recoverable credential. The per-field limits are four MiB
of input characters, 256 encoded candidates, one MiB of decoded bytes, four encoding layers,
8,192 combined parsed JSON nodes, raw string tokens, bare escape runs and percent runs,
4,096 redaction spans and 67,108,864 counted comparison characters.
An encoded candidate over 262,144 characters is redacted conservatively. Exceeding a shared work
limit or the regex timeout replaces untrusted output with `[redacted: diagnostic scan budget]`
instead of retaining an unchecked tail. Span and work limits include all recursive decoding.
Trusted executable paths and argv are checked for known credentials without conservatively
changing benign encoded text. A credential match or inspection limit refuses the record before
writing; published executable paths, argument arrays and process outcome metadata remain exact.
The invocation shares one inspection budget across the executable and all arguments.
`Redacted` reports output changes. Output excerpts keep the beginning and end, with `Truncated` set
when content is omitted. The limit is eight records, one MiB each; stdout is limited to 32,768
characters and stderr to 8,192. Oversized argv is refused rather than silently altered. A write
failure fails the battery and cannot authorize live evidence. These private diagnostic records
are not certification evidence. Successful controls retain no output, and an all-green run leaves
an empty diagnostic child. Records survive credential cleanup; remove them only when you have
finished inspecting them. Do not publish their contents without reviewing the redactions.

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
   present;
4. registers `gauntlet-core` and `gauntlet-peer` with Claude Code at user scope, both
   starting `python -m gauntlet_review.launch` from the collaborative venv
   (`-McpPython` picks the venv, `-StateRoot` the review-state folder,
   `-SkipMcpRegistration` skips this step). It first resolves the interpreter to an absolute
   path and runs the launcher's dependency check there (`python -m gauntlet_review.launch
   check`, the servers' exact pins); it warns and skips, changing nothing, when `claude`, the
   venv, the configuration or that check fails, and when `CLAUDE_CONFIG_DIR` is set without
   `-ClaudeConfig` naming that profile's configuration. If a replacement fails, the changes it
   made are undone, the result is read back, and the install stops, naming any entry that is
   not as it was (its original definition kept in a backup only you can read).

Start a new Claude Code session after installation so skill discovery and the servers load
from a clean session.

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
provenance mismatch. See [`gauntlet-review/LEGACY.md`](gauntlet-review/LEGACY.md) for the full legacy protocol.

## Update or reinstall

After pulling changes to this repository, run the offline suite and `install.ps1` again. If the
installer reports stale stack identity or live evidence (commonly after a Codex CLI, schema,
invocation-policy, or account-level `~/.codex/AGENTS.md` change), repeat the complete sequence.
First verify the existing trusted `%USERPROFILE%\.codex\AGENTS.md` prerequisite above and
explicitly authorize the actual security invocation and its owned-tree cleanup again. Missing
instructions or an omitted cleanup opt-in still refuse certification; do not bypass either check.

```powershell
pwsh -File .\gauntlet-review\scripts\calibrate-premises.ps1
pwsh -File .\tests\live\live-schema-gate.ps1
$diagnosticsRoot = Join-Path $env:LOCALAPPDATA 'gauntlet-review\diagnostics'
New-Item -ItemType Directory -Path $diagnosticsRoot -Force | Out-Null
pwsh -File .\tests\live\live-security.ps1 -AllowOwnedSecurityTreeCleanup -FailedControlDiagnosticsRoot $diagnosticsRoot
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

The live security battery requires independent positive, hermetic-negative and pairwise-isolation
controls for shell, web, MCP, apps and plugins. Computer-use, skill-search and subagent spawning
remain configured off without independent control proof on the headless stack. A generic MCP
server event without tool identity cannot promote computer-use to a proved class. Every narrowed
control still runs and any novel event fails certification. See [`docs/design.md`](docs/design.md)
and the [current evidence correction](docs/build-log/2026-10-14-live-review-compatibility.md).

Owned security-profile cleanup has one finite 60-second deadline per attempt; schema and empty
harness cleanup retain their 10-second limits. A failed attempt retains ownership and blocks
producers and readers. An explicit retry is admitted only after the original native work settles,
using its original handles; unresolved work and disposal intent refuse retries. Successful native
delete dispositions are retained across a deadline so a retry can verify completion without
reopening or deleting a replacement path. No automatic retry loop or pathname fallback is used.

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
