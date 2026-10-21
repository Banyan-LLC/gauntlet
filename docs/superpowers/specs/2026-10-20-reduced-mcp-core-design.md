# Reduced collaborative MCP core

Status: proposed design; implementation requires written-spec and plan approval.

**2026-10-21 amendment:** The Human Overlord directed migration to the Codex
app server through the Python SDK and requires a real Claude↔Codex workflow
before PR publication. The host-integration amendment below supersedes the
removed `codex`/`codex-reply` conversation endpoint references. The original
approved blob `b3326f11143be16b0f7a4a674f0c2492a6bd26d1`, its reviews and execution
evidence remain preserved in Git and the evidence archive.

## Purpose and approved direction

Retain Gauntlet's useful deterministic review records while moving agent conversations,
session lifecycle, model selection and tool access to native agent hosts. The first
useful slice is a local review of a committed branch: an author prepares a revision,
a tool-enabled peer reviews pinned source, the author fixes findings, and a later peer
review explicitly accounts for every earlier finding.

The user selected collaborative MCP reviews and retention of the legacy hermetic
mode. This design therefore introduces a separate `collaborative-v1` assurance
profile. It does not activate the dormant native/generic foundation from PR #13,
change old certificates, or transfer the foundation's review exceptions to new work.

Success means that Claude and Codex can use their native interfaces for conversation
while a small, model-neutral core records exactly which source was reviewed, preserves
findings and evidence, and refuses to report a superseded review as current.

## Alternatives and scope

1. **Recommended: local MCP record and policy service.** Native hosts own peer-agent
   calls; the core owns source snapshots, append-only history and derived status.
   This removes orchestration without discarding review continuity.
2. **Messaging only.** Agents exchange prose through native tools. This is smaller,
   but findings, evidence provenance and source freshness depend on conversational
   discipline. It does not retain enough of Gauntlet's value.
3. **Preserve hermeticity inside the new MCP path.** A custom supervisor still isolates
   every reviewer, packages all input and certifies runtime premises. This retains
   much of the machinery the user wants to reduce. The existing mode remains the
   explicit option for that assurance instead.

Version one covers committed local branch reviews and a documented Claude Code to
Codex MCP example. It includes no scheduler, agent registry, custom messaging bus,
model subprocess runner, prompt compression protocol, automatic review loop, remote
MCP listener, GitHub writer, CI executor, or approval/merge/deployment operation.
Document-review workflows remain on the existing path for this first slice.

## Components and boundary

An optional Python package extra supplies one local stdio MCP server using the
official Python MCP SDK. It calls a small transport-independent core and a local
SQLite event store. A read-only Git-object adapter uses a maintained library rather
than invoking a shell, Git hooks, diff drivers, text conversion or external helpers.
The implementation plan must pin and verify the chosen SDK and Git-library versions.

The existing Python package's pure verdict normalization and carry-over validation
are reuse candidates, subject to compatibility tests. Its CLI/container orchestration,
broker, leases and process cleanup are outside the new dependency path. Installing
or importing the legacy package without the optional extra must continue to work.

The operator configures an absolute repository path, a separate absolute private
state directory, one source branch ref, one target ref and a participant ID/role for
each server process. Clients cannot supply filesystem roots, executable commands,
URLs to fetch or arbitrary refs. Author and reviewer hosts connect to separate stdio
processes sharing the same store. Each process exposes only tools permitted to its
configured role; tool arguments cannot select or override that identity.

This role separation prevents accidental misuse by cooperating hosts. It is not
authentication of a model, protection against a hostile same-user process, or proof
that two participant IDs represent independent people/models. The operator owns and
trusts the local hosts, repository and state directory. Source text, tool arguments,
review text and evidence claims remain untrusted data.

## Pinned source

An operator-assigned repository ID namespaces every record. Opening a revision
captures the configured refs' full commit OIDs and verifies both resolve to commits.
For version one the target tip must be an ancestor of the source tip; otherwise the
request fails with `NEEDS_SYNC`. The review is the complete target-tree to source-tree
change set. This deliberate restriction avoids ambiguous merge-base selection.

The adapter enumerates the complete ordered change manifest, including deletions and
mode changes, and records each old/new path, Git mode, blob OID, byte length and
SHA-256. Renames may be represented as deletion plus addition. Exact blob bytes are
the source of truth; there are no newline conversions, attribute filters or working
directory reads. Symlink blobs are data and never followed. Gitlinks are explicit
pointer changes, not claims that submodule contents were reviewed. Missing objects,
unsupported object formats/extensions and incomplete enumeration fail closed.
Git paths retain raw-byte identity, use reversible base64 in transport and sort by
unsigned byte order. A separate escaped display label is informational only. Case,
Unicode normalization and invalid UTF-8 never collapse paths or become OS filenames.

The snapshot digest binds repository ID, source/target ref names and OIDs, the full
manifest and the versioned policy. Refs are checked again before the snapshot is
committed; detected movement aborts it. A snapshot identifies the observed commits,
not an atomic lock on moving refs. Status and review submission independently check
freshness again. A changed ref is stale even when its tree is identical.

Pinned base/head blobs and additional source-tree files are readable through opaque
artifact IDs with byte offsets, explicit encodings, lengths, digests and end-of-file
markers. Listings are paginated with snapshot-bound cursors. A partial page is never
represented as a complete artifact. Any source read remains bound to its immutable
snapshot; moving the worktree cannot change returned bytes.

Freshness means equality to the configured **local** refs at the recorded check time.
The service does not fetch remotes or verify GitHub's live PR head. The host must
fetch and check live PR/CI state before publication. No server result is a durable
permission to publish, approve or merge. Dirty and untracked work is outside a
committed snapshot and must be committed before it can be included in a review.

## MCP interface and review flow

The public interface has five tools; operations are structured, not free-form commands.

| Tool | Role | Result |
| --- | --- | --- |
| `open_review` | author | Create a review, or append a new pinned revision to it; return IDs, manifest summary and store version. |
| `read_review` | author/reviewer | Read paginated history, manifest, pinned artifact bytes or stored evidence by opaque ID. |
| `record_evidence` | author/reviewer | Append exact bounded evidence bytes or a clearly labelled external-archive descriptor to the active revision. |
| `submit_review` | reviewer | Append a schema-valid peer verdict, complete coverage attestation and validated carry-over ledger. |
| `review_status` | author/reviewer | Recheck local refs and derive current revision, findings, evidence provenance and peer-review status. |

There is one persisted review series per repository ID and configured source/target
ref pair. `open_review` finds that series or creates it under a database uniqueness
constraint; clients cannot create a replacement series for the same pair. Policy
changes cannot reset it. New revisions, process restarts and limit refusals preserve
its findings and counters. Operator configuration changes or deletion of the store
are outside this cooperative boundary and cannot be presented as continuation of
the same recorded review.

Every mutation includes an idempotency key and expected store version. Exact retries
return the original result, including after a lost response; reusing a key for different
content fails. A non-retry with an old version fails with `CONFLICT`. Successful
reads/status responses include their observed store version, and mutation responses
include the resulting version. On conflict either role can refresh through
`review_status`, reconsider the intervening events and submit with a new idempotency
key/version; blindly changing the version of an old request is not a retry.
Requests bind
review ID, revision ID and snapshot digest. Only the current revision accepts new
evidence or verdicts. Rejected/stale submissions cannot make status complete.

The native host gives its peer the review/revision IDs, scope and server access.
It chooses model, permissions, prompt, session continuity, timeouts and cancellation.
The core never calls a model or waits for a peer. The separate host adapter connects
Claude Code through the official Python SDK to the Codex app server; the record
protocol itself does not depend on Codex being reviewer or Claude being author.

A verdict uses `approve` or `request_changes`, recommendations with severity
`blocking`, `important` or `nit`, and a prose summary. Approval containing any new
non-nit finding is normalized to `request_changes`. Findings receive deterministic
IDs using the existing round/index/content scheme, namespaced by review ID.

Each subsequent accepted verdict accounts for every finding from all previous accepted
verdicts exactly once. A carry-over entry references the immutable finding ID and record
digest rather than resending its text; the core resolves and preserves the original
severity, location, issue and suggestion. Unknown IDs, digest mismatches and attempts
to replace that text fail validation. Each entry is `addressed`, `disputed` or
`outstanding`; the latter two require reasons.
Only an `addressed` non-nit can close that blocker. A disputed or outstanding non-nit
keeps the review in `changes_requested`, even if the new verdict says approve.
The reviewer owns these dispositions; an author's conversational claim cannot close
a finding. Older verdicts and dispositions remain readable after any later decision.

The coverage attestation lists the exact complete change-manifest digest and explicitly
acknowledges every changed artifact, including binary bytes, deletions, modes, symlinks
and gitlink pointers. Missing/unknown coverage entries refuse acceptance. Coverage is
a recorded reviewer claim; it does not prove model reasoning, retained context or
complete inspection. Host tool access and model telemetry are outside the core.

## Evidence, persistence and derived status

Evidence records bind exact bytes/digest, revision, producer participant and producer's
claims about command, runtime, exit status and origin. The core computes digests for
bytes it actually stores. It does not execute commands or independently verify those
claims. External archives retain their supplied URI/path, length and digest as
**unverified references**; the service never opens or fetches those locations.
Agent reports, CI receipts and legacy certificates retain distinct origin labels;
labels alone do not make any of them verified CI or inherit legacy certification.

SQLite transactions atomically append events, store evidence bytes and advance a
monotonic version. Acknowledgement follows a successful durable commit. No public
update/delete/reset-history API exists. A crash before commit leaves no accepted
event; a crash after commit is recoverable through idempotent retry. Concurrent
processes use compare-and-swap version checks and bounded lock waits. Failed writes,
unreadable history, unsupported schema versions and detected digest inconsistencies
produce errors, never an empty clean history. The store is an audit trail under the
trusted local operator, not a tamper-proof log against that operator.

Status is computed from persisted events, never a client-supplied `approved` flag:

- `awaiting_review`: current revision has no accepted verdict.
- `changes_requested`: latest verdict requests changes or any non-nit remains open.
- `peer_complete`: latest verdict approves, coverage and carry-over are complete,
  no non-nit remains open, and configured local refs still match the snapshot.
- `stale`: either configured local ref no longer matches the current snapshot.

Errors are distinct from those four states and cannot be interpreted as completion.
Every response includes assurance profile, available revision/snapshot identity and a
freshness discriminant: `match`/`stale` with the actual observation time and OIDs,
`not_checked` for an immutable historical read or replayed result, or `unknown` when
the check failed. Identity is explicitly null when creation has not succeeded.
An idempotent retry preserves the original mutation result and its original observation;
the response envelope does not present it as a new check. Only `review_status` derives
current completion from a new successful ref observation. Nits remain visible when
`peer_complete`. Evidence presence or a
self-reported green test never turns this status into CI success, hermetic certification,
human approval or merge authorization. A new source revision requires a new verdict;
prior findings carry forward while prior approval does not.

## Limits, errors and filesystem behavior

Version-one defaults are fixed policy inputs: 1,000 changed paths, 4 MiB per source
blob, 64 MiB total changed old/new bytes, 64 KiB artifact pages, 256 KiB stored evidence
per call, 16 MiB stored evidence per review, 256 KiB verdict payload, 200 findings per
review, 20 new findings per verdict, 10 accepted verdicts and 20 revisions per review.
Carry-over reasons are at most 256 UTF-8 bytes each. The verdict schema must reserve
space for a full carry-over ledger at maximum reason lengths and coverage of the
maximum manifest before accepting any new findings; the implementation plan must
prove this fits the payload cap and specify all remaining metadata/string bounds.
An earlier valid verdict must never make a later closure payload unrepresentable
within the remaining verdict/revision budget. This is a payload-capacity guarantee,
not an additional verdict or revision beyond the fixed caps. Exhaustion can leave
findings open; it preserves them and refuses further mutations rather than claiming
completion or resetting history. A separate explicit policy change would be needed
to extend a consumed budget.
Total event/evidence payload is
limited to 64 MiB per review and 1 GiB per store; failure to reserve space refuses a
mutation atomically. These are logical application payload quotas, not a claim about
physical SQLite file size, SDK/parser allocations or Git decompression memory.

There is no silent truncation, history pruning or automatic limit increase. Larger
source snapshots fail with `LIMIT_EXCEEDED`; the host can use the legacy mode or
request a separately designed policy change. Large logs can remain in external
archives as unverified descriptors without being treated as stored/verified bytes.
No limit refusal drops earlier findings or authorizes a new review to bypass them.

Malformed arguments, unauthorized roles, missing objects, stale refs, unsupported
repositories, digest mismatches, conflicts, limits, storage failures and lock timeouts
have stable error codes with safe structured detail and retryability. Exceptions
remain typed inside the core. stdout contains MCP protocol only; stderr diagnostics
exclude source/evidence bodies and credentials. Cancellation before commit aborts the
mutation; once committed, retry discovers the committed result. No background job,
subprocess, model session or unbounded cleanup loop is created by the five-tool core.

State uses one operator-created directory outside the working tree and legacy state.
Startup and core database opens reject symlink/reparse components in the state
path, including the database and its journal, WAL and SHM sidecars; only genuine
ENOENT is absence, and other stat/open failures refuse use. No request-supplied
temporary entry is opened. Repository metadata/object storage remains trusted
operator configuration under the separate cooperative boundary below;
existing regular database files are accepted after schema/integrity validation.
no request-derived filesystem path is opened, and no cleanup recursively deletes
anything. The operator must preserve ordinary local directory ownership and avoid
concurrent path replacement. Repository metadata, linked-worktree pointers and object
storage are trusted operator configuration, not a sandbox for hostile repositories.
Network filesystems, adversarial packfiles and hostile same-user filesystem races
are outside version-one support. Blocking OS I/O has no certified hard deadline.

## Compatibility, rollout and acceptance

Support Python 3.11+ on Windows, Linux and macOS with equivalent observable semantics.
Normal repositories and linked worktrees are required fixtures. Optional dependencies
and configuration are explicit opt-in; existing PowerShell and Python entry points,
default behavior, state directories, certificates and review history remain intact.
No legacy history is imported or rewritten. No deferred PowerShell 7.2 defect is
waived for activation by this feature.

The first implementation must demonstrate:

1. Two independent native-host connections share one review: pinned revision, evidence,
   a blocking finding, a committed fix and a later verdict preserving/closing that ID.
2. Head drift, target drift, missing objects, malformed coverage, omitted/reworded prior
   findings, unknown IDs, approval-with-blockers and role misuse refuse clean completion.
3. Concurrent writes, exact/conflicting retries, cancellation and crashes around commits
   preserve history and yield deterministic recovery without duplicate verdicts.
   A second participant and a restarted process can reopen the existing store.
4. Exact byte handling, page boundaries, all quotas and Unicode/binary/mode cases work
   consistently; symlink contents are data, and request strings cannot open host paths.
   Raw non-UTF-8, case-distinct and normalization-distinct Git paths retain separate
   identities and identical manifests on all supported platforms.
   A near-limit accepted finding set can be closed with a complete carry-over ledger;
   reopening the same ref pair after quota refusal cannot reset findings or counters.
5. Legacy tests remain passing within their established supported-runtime boundaries;
   installing the legacy package without the extra neither imports nor starts MCP.
6. A documented, explicitly collaborative Claude-to-Codex MCP walkthrough uses pinned
   dependencies and user-owned host configuration, preserves records, and performs no
   automatic GitHub approval or merge. Deterministic protocol tests do not require a
   paid model; the live walkthrough is separately recorded as integration evidence.

Roll out this first slice alongside legacy mode. Any later remote transport, external
identity, trusted CI verification, automated publication, document workflow or legacy
retirement requires its own explicit design and review.

## Host-integration amendment: Python SDK and app server

The review core and its five tools remain model-neutral and subprocess-free.
A separate, optional local stdio MCP **host adapter** provides the conversation
connection: Claude Code → adapter → official Python Codex SDK → local Codex
app server. This expressly permits the SDK's native runtime lifecycle in that
adapter, not in the review core. The adapter adds no scheduler, automatic review
loop, agent registry, raw JSON-RPC implementation, GitHub writer or legacy-mode
activation. Direct app-server JSON-RPC would require maintaining more protocol
code; restoring a removed MCP server or downgrading the CLI is rejected.

Pin `openai-codex==0.163.0`, whose published dependency pins
`openai-codex-cli-bin==0.163.0`, alongside the existing exact MCP/Pydantic/Git
pins in a separate `codex` extra. The verified SDK wheel SHA-256 is
`d151e3ff8188bc2c07a962855d598b93bf87a49ec3440810e45a5f2e1167d99e`.
Use the packaged runtime by default. No executable override is exposed to MCP
clients. Missing/wrong optional pins refuse startup without importing or
affecting the legacy package/core. Python 3.11+ and the existing three-platform
matrix remain required; unavailable native runtime wheels are a qualification
failure, not an inferred pass. The SDK is stable; the underlying app-server
command remains experimental. Record both versions in live evidence.

Operator-only CLI configuration fixes absolute repo/private-state paths, repo
ID, source/target refs and reviewer participant, using the same validation as the
core. The SDK config registers a required reviewer-role `gauntlet-reviewer`
MCP process using that interpreter and tuple. The model uses the native host's
configured default unless the operator explicitly supplies one. Reviewer turns
use read-only sandbox and deny escalation; this does not prohibit the separate
MCP core from recording reviewer verdicts in its configured private state.
Native user authentication/configuration remains user-owned; do not copy
credentials, rewrite global host configuration or open a network listener.
This is collaborative native-host access, not hermetic isolation from the
native host's existing configuration or proof of model independence.

One adapter process owns one SDK conversation and a fresh random instance ID.
`codex_status` returns this ID, owned thread ID and ready/poisoned/busy state without
starting a model turn. `codex_review` accepts only that required instance ID, a
bounded key, prompt and nullable expected thread ID. Check the instance ID before
cache lookup or native work: a retry carrying the previous process's ID returns
structured `ADAPTER_RESTARTED` uncertainty, including for a lost first response.
The caller must not automatically replace the instance ID and repeat that request.
First use
creates the thread; later new turns require its exact returned ID. Clients
cannot select models, permissions, refs, paths, executables or arbitrary saved
threads. Exact-key replay returns the original response without a second turn;
different content conflicts. Admit at most 20 keys, 64 KiB UTF-8 prompt, 128 KiB
returned text, 256 KiB complete serialized MCP result and 4 MiB total logical
cache bytes per process, counting keys, prompt digests, responses and metadata.
Cache prompt SHA-256, not prompt bodies. Consume SDK notifications incrementally
with an 8 MiB decoded-event total per turn. On a crossed logical cap, immediately
stop consuming/retaining application events and interrupt/close; never truncate.
SDK-owned pre-parse buffers and native stdio are outside these application caps.
Only a matching successful terminal notification AND a validated complete final
message from the same thread/turn permit success. Missing/invalid final messages
or EOF before the matching terminal event refuse success. Return thread/turn IDs
and the complete final message, not a claim of review
completion. There is no `peer_complete` field in this adapter's results.

There is one active call per adapter. Concurrent calls refuse with `BUSY`.
The operator sets a per-call application deadline (default 600 seconds, range
10–1800), reserving five seconds within it for interruption/SDK close. Timeout,
cancellation, stream loss, invalid terminal state, overflow or SDK failure
poisons the conversation: attempt native interruption/close within the remaining
budget, preserve a safe uncertain/error response and refuse further new turns.
These bounds limit application waits; they do not promise termination/reaping of
native SDK worker threads or descendants within that wall-clock interval.
Never automatically retry a model call. Cancellation propagates after cleanup.
Diagnostic codes/correlation IDs exclude prompts, responses, exception strings
and credentials. Internal `BridgeError` retains its underlying typed cause through
exception chaining. External errors have a fixed `code`, safe `cause` category,
correlation ID, `uncertain` boolean, `partial_usable=false`, available thread/turn
IDs and structured cleanup outcomes (`not_attempted`, `succeeded`, `failed` or
`timed_out`). Categories distinguish invalid input, instance/thread mismatch,
conflict, busy, logical limit, deadline, cancellation, SDK/RPC/transport failure,
missing terminal/final message and cleanup failure. No partial model text is
returned as usable data. A native close result never certifies process retirement.
SDK buffers, threads, OS blocking and process-tree retirement
are native-host responsibilities, not newly certified physical resource bounds.
Deterministic/live verification uses the existing external native test owner to
prove actual process closure; SDK close alone is not a closure receipt.

Retry cache/ownership is process-local and bound to the fresh instance ID.
Restart does not implicitly resume an
arbitrary native thread or recreate a lost turn. A caller carrying the previous
thread ID receives a mismatch before any new model work. An explicit fresh
conversation must re-read the existing Gauntlet review and every prior finding;
it does not reset core history/counters. Native SDK conversation history stays
in the native host's user-owned storage. No adapter operation deletes it.

Acceptance paragraph 6 now requires a real, separately labelled integration run
on a disposable local Git repository. A real Claude Code author calls the core,
then the adapter; the real Codex peer reads complete pinned source/history and
submits a non-nit finding through its reviewer-role MCP tools. Claude makes a
committed fix, opens the next revision and invokes the same Codex thread. Codex
must submit a later verdict with the original finding ID/digest addressed.
Independently inspect the persisted core records: distinct revision OIDs,
evidence bytes/digests, complete carry-over, and fresh `peer_complete`. Verify
both conversation turns share a thread ID and have distinct terminal turn IDs.
Preserve native host versions, full bounded transcripts, canonical core records,
source OIDs, evidence and actual process-closure receipts. A prose success,
transport handshake, fake peer or deterministic SDK stub cannot pass this gate.
Keep every failed attempt. Missing auth/capability leaves publication held.

Model-free tests must cover schemas/import isolation, configuration/role locks,
same-thread continuation, exact/conflicting retries, concurrency, all logical
caps, cancelled/failed/missing terminal turns, SDK close failures, poisoned-state
refusal and safe diagnostics. An installed-SDK/no-model smoke test verifies the
pinned runtime handshake and configured reviewer MCP discovery. Existing core,
legacy and native ownership tests remain required. Local branch review precedes
one authoritative PR review; no PR is published before the live gate passes,
and this chat neither approves nor merges it.

Amendment interface references:
[Python SDK](https://learn.chatgpt.com/docs/codex-sdk),
[app-server protocol](https://learn.chatgpt.com/docs/app-server),
[removed conversation MCP endpoint](https://learn.chatgpt.com/docs/mcp-server),
[Claude Code programmatic CLI](https://code.claude.com/docs/en/headless).

## Original interface references (historical)

- [Official Python MCP SDK](https://py.sdk.modelcontextprotocol.io/)
- [Codex MCP tools and native agent-host example](https://developers.openai.com/cookbook/examples/codex/codex_mcp_agents_sdk/building_consistent_workflows_codex_cli_agents_sdk)
- [Claude Code MCP connections](https://code.claude.com/docs/en/mcp)
- [Dulwich local repository API](https://www.dulwich.io/api/dulwich.repo.html)

These describe available interfaces; the proposed boundaries and guarantees above
are Gauntlet design decisions, not guarantees supplied by MCP itself.
