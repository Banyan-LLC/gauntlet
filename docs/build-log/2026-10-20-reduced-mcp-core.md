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
| Clean functional source, current PowerShell 7.6.6 | First attempt reached its 900-second deadline; incomplete, tree retired; longer fresh run pending | `task8-powershell-v1` |
| Review fixes, Windows Python 3.14.6 | 28 custody probes passed, two POSIX-only skips; 221 collaborative and 145 legacy tests passed, six legacy/environment skips | `implementation-matrix314-v3` |
| Review fixes, Windows Python 3.13.7 | Same 28 / 221 / 145 passed with the same explicit skips | `implementation-matrix313-v2` |
| Final clean-source Python/base verification | Pending Task 8 completion | final execution evidence index |
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
| 1. Shared pinned review, evidence, blocker, committed fix and preserved closure | `test_two_stdio_hosts_keep_history_source_and_evidence_after_restart`; four distinct native host PIDs across restart; original finding/evidence/source bytes re-read; independent author/reviewer core flow | Separately recorded native model-host conversation, described in paragraph 6 |
| 2. Drift, missing objects, malformed coverage/ledger, blockers and role misuse refuse completion | `test_core.py`, `test_policy.py`, `test_source.py`, role-specific SDK tests; real stdio head/target drift and exact replay | Cross-platform CI results pending |
| 3. CAS/retries, cancellation, crashes, restart and second participant | Real before/after-COMMIT process exits 73 with required control checkpoints; exact-key recovery once; cancellation at three Store checkpoints and through SDK; post-COMMIT lost response; two-connection CAS | Cross-platform CI results pending |
| 4. Exact bytes, quotas, raw paths, complete near-limit carry-over and persistent counters | `test_contracts.py`, `test_source.py`, `test_store.py`, `test_policy.py`, `test_path_security.py`; Git objects for case/normalization/raw-byte paths; whole-byte digests and pages; real 180-prior-finding closure in round ten | Cross-platform CI results pending; physical resource certification is outside the approved logical quotas |
| 5. Legacy compatibility and base-only isolation | Legacy suite remains green on both installed supported Python runtimes; separate base-only venv has no optional dependencies; console missing-extra diagnostic is short and safe | Final PowerShell/base checks and remote floor job pending |
| 6. Documented collaborative Claude-to-Codex native conversation walkthrough | Operator configuration and complete reading/submission flow documented; installed host versions and capability failures preserved | **Live walkthrough blocked:** both installed Codex binaries lack `mcp-server`; no native model-to-model pass is claimed |

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

Six pre-hardening reviews are preserved under `prehardening-d06c1df` in the raw
execution archive. Their verified findings produced regression tests and fixes
for common-path receipt validation, filesystem probe errors, known stale ref
observations, unsupported empty database versions, independent cleanup, fatal
diagnostic handling and POSIX process custody. The POSIX launch handshake and
legacy-session registration require native CI; Windows results do not certify
them. Earlier failed test attempts remain preserved beside the passing runs.
