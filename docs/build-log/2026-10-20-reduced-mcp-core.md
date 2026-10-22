# Reduced MCP core implementation evidence

The approved [spec](../superpowers/specs/2026-10-20-reduced-mcp-core-design.md)
and [plan](../superpowers/plans/2026-10-20-reduced-mcp-core.md) remain intact.
The implementation is opt-in `collaborative-v1`; legacy hermetic behavior,
certificates, history and dormant helper activation boundaries are unchanged.
The native inline execution approval and all earlier review rounds are retained
in [the review history](../superpowers/reviews/2026-10-20-reduced-mcp-core).

## Configuration and rollout

Using this feature requires installing the optional exact dependency pins and
registering a local stdio process in each user-owned host configuration. All seven
CLI fields are required: absolute repository/state paths, repository ID, full
local source/target refs, participant and role. State must already exist, be
private/local, and be outside the reviewed checkout/common Git directory and
legacy state. Participants share repository/state/ref configuration but have
different IDs/roles. Host configuration/package changes require a host reload or
restart. No new environment variable, secret, production setting or migration
is required. Invalid configuration or bindings fail closed; installation does
not modify host configuration. See the [complete operator guide](../collaborative-mcp.md).

## Measured local results

The functional/test implementation through Task 7 is commit
`ea5eff6c999cabcca31d41454d853d2a4179a49e`. Windows 11 build 26200 is the
local platform. Each matrix archive includes exact source-file hashes,
interpreter/dependency metadata and original process outcomes; early Task 7 runs
identify their working source separately from their parent commit.

| Check | Actual result | Original evidence archive |
| --- | --- | --- |
| Windows Python 3.14.6 / SQLite 3.50.4 | 24 custody probes; 195 collaborative tests; 145 legacy tests passed, six explicit skips | `task7-matrix314-v1` |
| Windows Python 3.13.7 / SQLite 3.50.4 | Same 24 / 195 / 145 passed, six explicit skips | `task7-matrix313-v1` |
| Focused real stdio, recovery, path security and matrix controller | 22 passed; actual exit 0 and full native tree retirement | `task7-task-done-v1` |
| Separate base-only Python 3.14 environment | Full base suite passed without MCP/Dulwich/Pydantic; missing-extra startup and import isolation passed | `task6-base-suite-v1` |
| Clean functional source, current PowerShell 7.6.6 | First attempt reached its 900-second deadline; incomplete, tree retired; preserved separately | `task8-powershell-v1` |
| Clean `b8bd4d8`, PowerShell 7.6.6 | All 40 test files passed; 7,281 assertions; actual exit 0 and full native retirement | `task8-powershell-v2` |
| Review fixes, Windows Python 3.14.6 | 28 custody probes passed, two POSIX-only skips; 221 collaborative and 145 legacy tests passed, six legacy/environment skips | `implementation-matrix314-v3` |
| Review fixes, Windows Python 3.13.7 | Same 28 / 221 / 145 passed with the same explicit skips | `implementation-matrix313-v2` |
| Final branch-review fix, Windows Python 3.14.6 | 28 custody probes passed, two POSIX-only skips; 224 collaborative and 145 legacy tests passed, six legacy/environment skips | `final-matrix314-v1` |
| Fresh separate base-only Python 3.14.6 | 147 passed, four explicit inherited/environment skips; optional dependencies absent | `implementation-base314-v2` |
| SDK migration, clean `0f123b6`, Python 3.14.6 | Whole suite: 453 passed, seven explicit skips; exit 0 and full retirement | `app-server-migration/task11-postlive-full-suite-v1` |
| Final SDK/acceptance cases, Python 3.13.7 | 83 passed; exit 0 and full retirement | `app-server-migration/task11-final-bridge313-v1` |
| SDK migration base-only Python 3.14.6 | 148 passed, four explicit skips; optional dependencies absent | `app-server-migration/task10-base314-v1` |
| Linux/Windows/macOS × Python 3.11/3.14/3.15 plus base-only | Workflow configured; remote results pending publication | `.github/workflows/collaborative-python.yml` |

The six optional-environment skips are the existing Docker opt-in integration,
three POSIX-only legacy bounded-process cases on Windows, and two base-only
installation guards. File symlink tests for the database and all three sidecars
passed locally; ancestor/final-directory junction tests also passed. The matrix
requires capable Windows file-symlink coverage rather than silently accepting an
unsupported security fixture. No Linux/macOS or unavailable local Python runtime
pass is inferred from Windows results.

## Spec acceptance mapping

| Approved acceptance paragraph | Implemented evidence | Remaining acceptance |
| --- | --- | --- |
| 1. Shared pinned review, evidence, blocker, committed fix and preserved closure | `test_two_stdio_hosts_keep_history_source_and_evidence_after_restart`; four distinct native host PIDs across restart; original finding/evidence/source bytes re-read; independent author/reviewer core flow; real native proof in paragraph 6 | Remote CI remains required |
| 2. Drift, missing objects, malformed coverage/ledger, blockers and role misuse refuse completion | `test_core.py`, `test_policy.py`, `test_source.py`, role-specific SDK tests; real stdio head/target drift and exact replay | Cross-platform CI results pending |
| 3. CAS/retries, cancellation, crashes, restart and second participant | Real before/after-COMMIT process exits 73 with required control checkpoints; exact-key recovery once; cancellation at three Store checkpoints and through SDK; post-COMMIT lost response; two-connection CAS | Cross-platform CI results pending |
| 4. Exact bytes, quotas, raw paths, complete near-limit carry-over and persistent counters | `test_contracts.py`, `test_source.py`, `test_store.py`, `test_policy.py`, `test_path_security.py`; Git objects for case/normalization/raw-byte paths; whole-byte digests and pages; real 180-prior-finding closure in round ten | Cross-platform CI results pending; physical resource certification is outside the approved logical quotas |
| 5. Legacy compatibility and base-only isolation | Legacy suite green on both local supported runtimes; base-only 148 passed with optional packages absent; missing-extra diagnostics safe; unchanged PowerShell 40 files/7,281 assertions passed | Remote floor/base jobs pending |
| 6. Documented collaborative Claude-to-Codex native conversation walkthrough | `live-attempt-v2` from clean `0f123b6`: real Claude author, real SDK Codex peer; one thread/two terminal turns; two committed source OIDs; original non-nit finding closed by exact ID/digest; actual complete-read and native closure receipts independently verified | Live gate satisfied; final source review and remote CI remain separate gates |

## Payload and assurance boundaries

The actual maximal strict-model/JCS request proof with 1,000 coverage IDs,
200 carry-over entries, maximal escaped strings and 20 new recommendations is
**218,196 bytes**, leaving **43,948 bytes** below 256 KiB. Complete status and
artifact-page SDK `CallToolResult` serialization also stays within 256 KiB.
The capacity proof does not authorize an eleventh verdict: generating 200 findings
already consumes all ten accepted verdicts. The reachable closure test handles
180 prior findings in round ten; all 200 remain visible in the separate cap test.

The fixed limits remain 1,000 changed paths; 4 MiB/source blob; 64 MiB changed
old/new bytes; 64 KiB pages; 256 KiB inline evidence/call; 16 MiB evidence/series;
256 KiB verdict; 20 new and 200 total findings; 10 verdicts; 20 revisions;
256 UTF-8 bytes/carry-over reason; 64 MiB logical payload/series; 1 GiB/store.
These are logical payload bounds. They do not certify physical SDK/parser
memory, Git decompression, SQLite-file size or OS I/O. Coverage is attested;
stored evidence bytes are checked while command/runtime/origin/exit claims and
external descriptors remain unverified.

Source traversal additionally admits at most 100,000 tree-entry occurrences per
complete tree, counting directories before queuing them, including repeated empty
subtrees. The `all_entries_v1` accounting rule is bound into the policy digest.
The final fresh branch review identified this missing bound; object-level and
transaction regressions reproduced it before the fix and now pass.

Only fresh `review_status` derives `peer_complete`. Mutation acknowledgements
and exact retries cannot claim it. Local-ref freshness is independent of remote
PR freshness; hosts own fetching and live PR checks. Completion authorizes no
CI conclusion, legacy certificate, human approval, merge or deployment.

## Native host capability record

On 2026-10-21 the PATH Codex binary reported `0.160.1`; the exact binary used
by the approved plan reviews reported `0.163.0-alpha.10.2`. Both
`help mcp-server` probes returned actual exit 2 with `unrecognized subcommand`
and confirmed tree retirement. Claude Code reported `2.1.282`.
The [official removal guidance](https://learn.chatgpt.com/docs/mcp-server) and
[deprecated original recipe](https://developers.openai.com/cookbook/examples/codex/codex_mcp_agents_sdk/building_consistent_workflows_codex_cli_agents_sdk)
were checked against these installed interfaces. Current Codex still documents
consuming configured stdio MCP tools; that does not restore the removed
conversation server. No credentials or user host configurations were copied or
changed, and no fake live run was substituted.

The core remains host-neutral. Replacing the conversation route with a current
SDK/app-server integration is a separate host-integration decision. The pending
live acceptance is stated prominently so the Human Overlord can review it
separately from deterministic protocol correctness.

## Evidence custody and review

Original execution captures are retained outside the checkout under the common
Git directory, `info/reduced-mcp-core/20261021-execution/`. Committed
`execution-evidence-task*.json` indexes record each original's path, byte count
and SHA-256; incremental indexes retain the earlier manifests. The preserved
skill ledger and its committed snapshots contain task boundaries, RED/GREEN
attempts, rulings and completion commands. Nothing is truncated or reset to
discard a failed attempt.

Each spawned check uses the test-only native owner, with exact exits, bounded
capture, one inherited deadline and confirmed job/group retirement. Fatal
capability probes run in an external controller before spawned acceptance tests.
Two-host normal closure, out-of-order sibling closure, malformed protocol,
capture overflow, failed cleanup and real expiry with pipe-holding descendants
have dedicated cases. A changed schema, binding, object, record digest or retry
semantics refuses acceptance. Production code imports none of this test owner.

The deferred PowerShell 7.2 helper defects remain restricted to unchanged dormant
stages 2–3 and must be fixed before activation. This feature activates none of
them and changes no legacy history/certificate/source integration code.

Final review, authoritative PR review, remote CI and the publication handoff are
recorded as they complete. Approval and merge from this chat remain prohibited.

## App-server migration amendment

The Human directed migration through the official Python SDK and requires the full
real Claude↔Codex workflow before publication. The [spec amendment](../superpowers/specs/2026-10-20-reduced-mcp-core-design.md#host-integration-amendment-python-sdk-and-app-server)
and [plan Tasks 9–12](../superpowers/plans/2026-10-20-reduced-mcp-core.md#task-9-sdk-conversation-adapter-and-locked-configuration)
keep SDK lifecycle in a separate optional MCP adapter. The original approved spec
blob and pre-migration plan were archived create-only before amendment; original
canonical rounds and findings remain intact.

SDK `0.163.0` and its exact runtime dependency were checked against published PyPI
metadata and wheel hashes without installing or executing the SDK. Runtime wheels
exist for the required operating-system families; native qualification is pending.
All six amendment lenses ran; their three conformance gaps were fixed. Formal spec
rounds 2–3 and all original native process/usage/transcript evidence are preserved.
Round 3 accepted the restart-identity, final-message, typed-error and state-sidecar
clarifications. Its remaining three recommendations request native physical
retirement, physical memory bounds and closure beyond finite review budgets.
These conflict with the proposed disclosed SDK/cooperative assurance limits and
remain explicitly disputed pending Human disposition. No clean formal verdict,
SDK implementation, native handshake or live workflow is claimed yet. PR creation
remains held.

That preceding paragraph is the preserved pre-approval checkpoint. The Human
subsequently approved the amended spec/plan and all three stated assurance
exceptions; the exact answer and finding IDs are committed in
`app-server-approval.json`. Canonical spec request-changes verdicts remain intact
and are not relabelled as approvals. Amended plan rounds 3–7 preserve every
finding; round 7 approved with no recommendations. One failed attempt caused by
a relative output path also remains preserved, including its full advisory.

SDK implementation is now committed. Its 54 initial model-free cases and the
complete 423-test Python run passed. Native qualification added actual packaged
runtime handshake, required reviewer MCP discovery, real adapter stdio, scoped
SDK cancellation and externally owned expiry. Current local qualification:

| Environment | Measured result |
| --- | --- |
| Windows Python 3.14 | 225 core, 57 initial adapter, 145 legacy tests passed; seven explicit inherited/environment skips. |
| Windows Python 3.14 after known-ID fix | All 58 adapter cases passed, including actual native cases. |
| Windows Python 3.13 after known-ID fix | 225 core, 58 adapter, 145 legacy tests passed; seven explicit inherited/environment skips. |
| Native custody on both optional environments | 29 passed; two explicit POSIX-only skips. Real SDK expiry observed readiness and complete retirement. |
| Base-only Python 3.14 | 148 passed; four explicit inherited/environment skips; optional packages remain absent. |
| Existing MCP-only Python 3.13 before SDK installation | 11 passed; three base-only skips; SDK absence explicitly verified. |

Every successful command above retained original zero exits and full native
tree-retirement receipts. The strengthened SDK-scope cancellation probe was
verified separately on both runtimes; the earlier weaker waiter-cancellation
probe is retained and is not used for that claim. New identifier regressions
failed before status/refusals began exposing known SDK thread/turn IDs. The
unchanged PowerShell result remains 40 files and 7,281 assertions passed.

Both native auth preflights passed without credential copying. The live verifier
has 19 model-free cases for complete actual read receipts, request-digest binding,
canonical finding closure, exact retries, malformed input and restart recovery.
Five live-driver cases verify opt-in, clean committed fixture setup, original
declared failing/passing-test evidence and refusal of altered regression tests.
The pre-live checkpoint passed 450 tests with seven explicit skips; the subsequent
fixture-integrity regression failed before its guard and all five driver cases
then passed. None of
these results is a real model exchange: live Claude↔Codex acceptance, final review,
all nine remote platform jobs, base CI and authoritative PR review remain pending.

The first real workflow (`live-attempt-v1`, harness `d23b72a`) reached the native
Codex model, which attempted the reviewer tools. Native policy refused all four
calls with "MCP tool call requires approval, but approval policy is never".
Claude preserved the evidence and stopped without inventing a finding, fix or
verdict. Native execution itself exited zero with complete retirement; overall
acceptance failed. The controller's initial missing-file traceback is retained.
Both full native transcripts, typed SDK history, original test evidence and the
unchanged canonical core state remain intact.

The verified fix adds a fixed four-tool allow list and per-tool native approval
to the required reviewer server, retaining read-only sandbox and denied
escalation. A fixed output allowance prevents the smaller native default from
truncating bounded core replies. The public SDK configuration regression and a
typed missing-workflow-evidence regression failed before their fixes; all 83
adapter/verifier tests then passed. A fresh real attempt is required; the first
attempt is not counted as full live acceptance.

## Successful real Claude↔Codex proof

The next fresh run, `live-attempt-v2`, **passed** from clean harness `0f123b6`.
Claude Code 2.1.282 and the real Python SDK/packaged runtime 0.163.0 used native
user authentication. The independent verifier ran after complete process
retirement and derived fresh `peer_complete`. The
[committed proof record](../superpowers/reviews/2026-10-20-reduced-mcp-core/native-live-acceptance.json)
binds complete original transcripts, typed SDK history, canonical records,
fixture commits, evidence, runtime versions and native outcomes by SHA-256.

- Core review: `da569a570de245858f7279c6c77a4ad1`.
- Same native thread: `01a16102-e538-7d32-8a26-ec484e2194ff`.
- Completed turns: `01a16102-f214-7b81-bae7-54f3173045dd` and
  `01a16106-4f68-77d3-856d-8dd5ad4cdda2`.
- Committed source: `024d7e7fabec954c52b84105edb19fe15d544a9a` →
  `2851c71cbab543b8c9bd7e02247495bc99df065c`.
- Original non-nit finding: `r1-36fede18be7d32d2891289755f383be6`; its exact
  immutable digest was preserved in the addressed carryover.
- Original fixture tests: exit 1 before the committed fix, exit 0 afterward;
  exact full bytes matched both canonical inline evidence records.

Both native model turns read complete manifest, source-tree and history pages,
all required pinned blob/event/finding/evidence ranges through EOF. The verifier
compared those actual SDK MCP receipts with canonical bytes, lengths and hashes.
It did not accept coverage prose as proof. A too-long carryover reason was
refused without committing; the peer corrected it within the same turn. Six
canonical events remain: two revisions, two evidence records and two verdicts.
The original failure and corrected call both remain in native history.

The outer native owner completed with actual exit 0, root reaped and full tree
retirement in 417.47 seconds. Original vendor transcript files were copied
create-only after retirement and hash-checked against their native originals.
All fixture commits use the required author/committer and carry no tool credit.
No credential or global host configuration was copied or rewritten.

Post-live whole-suite verification passed 453 tests with seven explicit
inherited/environment skips on Python 3.14.6. The final 83 adapter/verifier cases
also passed on Python 3.13.7; all original exits were zero with complete native
retirement. This proof certifies that recorded Windows workflow, not model
independence, legacy hermetic isolation, universal SDK process retirement or
cross-platform CI. Final source review, nine native matrix jobs, base CI and
authoritative PR review still remain.

Six pre-hardening reviews are preserved under `prehardening-d06c1df` in the raw
execution archive. Their verified findings produced regression tests and fixes
for common-path receipt validation, filesystem probe errors, known stale ref
observations, unsupported empty database versions, independent cleanup, fatal
diagnostic handling and POSIX process custody. The POSIX launch handshake and
legacy-session registration require native CI; Windows results do not certify
them. Earlier failed test attempts remain preserved beside the passing runs.
