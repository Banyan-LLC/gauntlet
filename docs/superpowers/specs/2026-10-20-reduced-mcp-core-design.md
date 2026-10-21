# Reduced collaborative MCP core

Status: proposed design; implementation requires written-spec and plan approval.

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

Every mutation includes an idempotency key and expected store version. Exact retries
return the original result, including after a lost response; reusing a key for different
content fails. A non-retry with an old version fails with `CONFLICT`. Requests bind
review ID, revision ID and snapshot digest. Only the current revision accepts new
evidence or verdicts. Rejected/stale submissions cannot make status complete.

The native host gives its peer the review/revision IDs, scope and server access.
It chooses model, permissions, prompt, session continuity, timeouts and cancellation.
The core never calls a model or waits for a peer. Native Codex MCP `codex` and
`codex-reply` tools are the initial conversation example; the record protocol itself
does not depend on Codex being reviewer or Claude being author.

A verdict uses `approve` or `request_changes`, recommendations with severity
`blocking`, `important` or `nit`, and a prose summary. Approval containing any new
non-nit finding is normalized to `request_changes`. Findings receive deterministic
IDs using the existing round/index/content scheme, namespaced by review ID.

Each subsequent accepted verdict carries every finding from all previous accepted
verdicts exactly once, retaining its original severity, location, issue and suggestion.
Each entry is `addressed`, `disputed` or `outstanding`; the latter two require reasons.
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
Every response includes assurance profile, revision/snapshot identity and freshness
observation time. Nits remain visible when `peer_complete`. Evidence presence or a
self-reported green test never turns this status into CI success, hermetic certification,
human approval or merge authorization. A new source revision requires a new verdict;
prior findings carry forward while prior approval does not.

## Limits, errors and filesystem behavior

Version-one defaults are fixed policy inputs: 1,000 changed paths, 4 MiB per source
blob, 64 MiB total changed old/new bytes, 64 KiB artifact pages, 256 KiB stored evidence
per call, 16 MiB stored evidence per review, 256 KiB verdict payload, 1,000 findings per
review, 10 accepted verdicts and 20 revisions per review. Metadata and strings have
explicit schema limits in the implementation plan. Total event/evidence payload is
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
subprocess, model session or unbounded cleanup loop is created by the service.

State uses one operator-created directory outside the working tree and legacy state.
Startup rejects symlink/reparse components in its path and existing database files;
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
4. Exact byte handling, page boundaries, all quotas and Unicode/binary/mode cases work
   consistently; symlink contents are data, and request strings cannot open host paths.
5. Legacy tests remain passing within their established supported-runtime boundaries;
   installing the legacy package without the extra neither imports nor starts MCP.
6. A documented, explicitly collaborative Claude-to-Codex MCP walkthrough uses pinned
   dependencies and user-owned host configuration, preserves records, and performs no
   automatic GitHub approval or merge. Deterministic protocol tests do not require a
   paid model; the live walkthrough is separately recorded as integration evidence.

Roll out this first slice alongside legacy mode. Any later remote transport, external
identity, trusted CI verification, automated publication, document workflow or legacy
retirement requires its own explicit design and review.

## Primary interface references

- [Official Python MCP SDK](https://py.sdk.modelcontextprotocol.io/)
- [Codex MCP tools and native agent-host example](https://developers.openai.com/cookbook/examples/codex/codex_mcp_agents_sdk/building_consistent_workflows_codex_cli_agents_sdk)
- [Claude Code MCP connections](https://code.claude.com/docs/en/mcp)
- [Dulwich local repository API](https://www.dulwich.io/api/dulwich.repo.html)

These describe available interfaces; the proposed boundaries and guarantees above
are Gauntlet design decisions, not guarantees supplied by MCP itself.
