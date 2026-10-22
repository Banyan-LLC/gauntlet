# Reduced MCP Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an opt-in local collaborative review service that preserves pinned source, findings and evidence while native hosts own agent conversations.

**2026-10-21 migration amendment:** The Human directed app-server migration through
the Python SDK and requires the complete live workflow before publication. Keep
Tasks 0–7 and their evidence intact. The obsolete conversation endpoint in Task 8
is superseded by Tasks 9–12 below. Execution remains native; review remains local
first, then one authoritative PR round. No earlier review exception is inherited.

**Architecture:** A Python stdio MCP adapter calls a transport-independent review core backed by SQLite and a read-only Git-object adapter. Review history and policy are separate from host/model lifecycle; the existing hermetic route remains available with its original assurance boundary.

**Tech Stack:** Python 3.11+, SQLite from the standard library, MCP SDK 2.3.0, Dulwich 1.2.17, Pydantic 2.14.1, existing JSON canonicalization and finding-ID functions, pytest.

**Spec:** `docs/superpowers/specs/2026-10-20-reduced-mcp-core-design.md`, approved amended blob `f9b94a453e2c6248dd80c3f6d31be8178c7237e4` at commit `efdf3589c26941372e1c8c6a8a450f1ccc82f9e4`. Human approval and the three assurance exceptions are recorded in `docs/superpowers/reviews/2026-10-20-reduced-mcp-core/app-server-approval.json`. Original approval at `5c93d6b29d507ace5e7ad901e75a188924204ba2` and its `spec-approval.json` remain historical evidence. Do not edit the approved spec as an implementation shortcut.

## Global Constraints

- Assurance profile is `collaborative-v1`. Peer completion is neither CI success, legacy hermetic certification, human approval nor merge authorization.
- Support Python 3.11+ on Windows, Linux and macOS with equivalent observable semantics.
- Version one covers committed local branch reviews; document workflows remain on the existing route.
- One configured repository, source ref, target ref and participant/role per process; clients cannot override them.
- Target must be an ancestor of source; configured local refs determine observed freshness. Hosts own fetch/live PR checks.
- Git paths preserve raw bytes through base64; sort by unsigned bytes. Never materialize tree paths as OS paths.
- One persisted series per repository ID/source ref/target ref. Policy changes, restarts and limit refusals never reset its history.
- Only the current revision accepts new evidence/verdicts. A new revision requires a new verdict and preserves all findings.
- No shell, Git/model subprocess, hooks, filters, network listener, scheduler, CI executor, publication, approval or merge in the five-tool production core. The separate optional host adapter delegates native runtime lifecycle only to the official Python Codex SDK, as directed in the 2026-10-21 amendment; it adds no custom subprocess runner or raw JSON-RPC transport.
- Preserve existing entry points, defaults, certificates and history. Do not activate dormant native/generic helpers or waive the deferred PowerShell 7.2 defects.
- Fixed limits: 1,000 changed paths; 4 MiB/source blob; 64 MiB total changed old/new bytes; 64 KiB artifact pages; 256 KiB stored evidence/call; 16 MiB stored evidence/review; 256 KiB verdict payload; 200 findings/review; 20 new findings/verdict; 10 accepted verdicts; 20 revisions/review; 256 UTF-8 bytes/carry-over reason; 64 MiB event/evidence payload/review; 1 GiB/store.
- Quotas are logical payload bounds, not physical SDK/parser, Git decompression, SQLite-file or OS-I/O certification. No silent truncation, pruning or limit escalation.
- State is an operator-created, private, local directory outside the checkout and legacy state. Cooperative trusted local hosts/repository/ownership are the security boundary.
- Start from a clean isolated worktree; preserve every existing change. Use `feat/`, `fix/` or `chore/` branches. GitHub commits and publication use `geoffroth <geoffroth@gmail.com>`; no attribution trailers.
- Coordinate heavy test/compiler/live-review windows, retain original process closure evidence, batch pushes, target `main`, and never approve or merge from this chat.

## Review Focus

1. A lost response followed by retry after head drift must return the original committed result with `not_checked`, never a fresh completion claim (Task 3/5).
2. Git names that collide under case folding or Unicode normalization must remain distinct even on Windows; test Git objects rather than creating those host filenames (Task 2).
3. A second host must reopen the same regular database, while a symlink/junction or malicious sidecar is rejected without deletion (Task 3/7).
4. A valid near-limit finding set must permit a later all-addressed ledger even when text contains quotes/backslashes and four-byte Unicode (Task 1/4).
5. Cancellation or a crash around COMMIT must yield either no accepted event or one recoverable event, never a duplicate or false rollback acknowledgement (Task 3/6/7).

## File map and dependency verification

All product paths below are relative to `gauntlet-review/python/`.

| File | Responsibility |
| --- | --- |
| `gauntlet_review/collaborative/__init__.py` | Empty optional-subsystem namespace; no startup/import side effects. |
| `gauntlet_review/collaborative/contracts.py` | Strict request models, policy constants, typed domain error and response envelopes. |
| `gauntlet_review/collaborative/source.py` | Read-only Git commits/refs/manifests and exact object-byte pages. |
| `gauntlet_review/collaborative/store.py` | Checked local state path, SQLite schema, transactions, idempotency and durable history. |
| `gauntlet_review/collaborative/policy.py` | Finding identities, normalized verdicts, coverage, carry-over and status reduction. |
| `gauntlet_review/collaborative/core.py` | Role-aware operations combining source, store and policy. |
| `gauntlet_review/collaborative/server.py` | Five named MCP tools, strict startup configuration, stdio and safe errors. |
| `gauntlet_review/collaborative/__main__.py` | Delegate `python -m gauntlet_review.collaborative` to `server.main`. |
| `tests/collaborative/conftest.py` | Shared repository/store fixtures, request builders and cancellation/fault checkpoints. |
| `tests/collaborative/test_{contracts,source,store,policy,core,server,recovery}.py` | Focused acceptance and adversarial cases. |
| `tests/collaborative/test_stdio.py` | Real independent SDK stdio clients and process restart tests. |
| `tests/test_optional_install.py` | Base-only installation/import behavior; no optional import at collection. |
| `pyproject.toml` | Exact optional pins, console entry point, package discovery remains unchanged. |

Repository-level additions: `docs/collaborative-mcp.md`, a short opt-in README link,
`tests/run-collaborative-matrix.py`, `.github/workflows/collaborative-python.yml`,
and `docs/build-log/2026-10-20-reduced-mcp-core.md` for measured results.
Test-only additions: `tests/support/collaborative_process.py`,
`tests/support/test_collaborative_process.py` and bounded worker/probe fixtures.
They are outside the installed package and unavailable to the production MCP core.

Metadata checked during planning from version-specific PyPI JSON, without installing
or importing dependencies: MCP 2.3.0 and Dulwich 1.2.17 require Python >=3.10 and
publish pure-Python universal wheels. The MCP wheel SHA-256 is
`dd0c44c089d16453e8ae31a3877a0054d7a2314caaa81f5e0541b9b1734b2377`;
the Dulwich universal wheel is
`82555d6ea6d728ed722fdfcde6658e3d2b1774ad916260fdfd90a2e7af64291a`.
Both hashes were verified while inspecting their wheel source. Pydantic 2.14.1
metadata also declares Python >=3.10. These are metadata/source checks, not claims
that the dependency combination has already passed runtime compatibility tests.

Use this optional dependency block; do not add extras to the base installation:

```toml
[project.optional-dependencies]
dev = ["pytest>=7.0"]
mcp = ["mcp==2.3.0", "dulwich==1.2.17", "pydantic==2.14.1"]

[project.scripts]
gauntlet-mcp = "gauntlet_review.collaborative.server:main"
```

Recheck version-specific release metadata and wheel hashes before installing. Record
resolved transitive versions for each test runtime; do not claim the three direct
pins lock the entire environment. Pin changes require documented compatibility
evidence and plan review if they alter the interfaces/boundaries below.

## Wire contracts and payload proof

All requests are `{"request": <strict model>}` in MCP tool arguments. Reject unknown
properties, booleans as integers, floats, non-finite values and invalid Unicode.
Models use `ConfigDict(strict=True, extra="forbid")`; core validation runs even
when called outside MCP. String budgets count strict UTF-8 bytes. Text rejects C0
controls except TAB/CR/LF, and rejects lone surrogates. Thus canonical JSON string
escaping costs at most twice its original UTF-8 bytes; raw Git paths use base64.

Identifiers: review/revision/artifact/change/evidence IDs are exactly 32 lowercase
hex digits; SHA-256 digests are exactly 64. Local finding IDs have format
`r[1-9][0-9]?-<32 lowercase hex>` with accepted round <=10, and are namespaced by
review ID. Validate using full matches. Idempotency keys are 1..64 ASCII characters
from `[A-Za-z0-9_-]`. Versions/offsets/lengths are strict integers 0..2^53-1.
Repository/participant IDs use the same ASCII alphabet and 1..64 bytes; configured
refs are full `refs/heads/...` or target `refs/remotes/...`, <=1,024 UTF-8 bytes,
validated by Git ref rules and resolved only from operator configuration.

Mutation request fields: `key`, `expected_version`, plus `review_id`, `revision_id`,
`snapshot_digest` after creation. `open_review` has no client-supplied review ID and
finds the unique series by configured repository/ref tuple. At opening it accepts
`key` and `expected_version`; zero is valid for a new empty store. `review_status`
without a review ID returns the configured series (or an explicit null series) and
store version, allowing either role to obtain the first version.
Compute a pre-creation `series_scope` digest from configured repository ID and raw
source/target refs. Retry uniqueness is `(series_scope,participant,operation,key)`.
The request fingerprint binds scope, configured role, policy digest and complete
canonical request. A client cannot select scope. Identical keys in different
configured series are independent; changed content within one scope conflicts.
Repository binding is a startup-validated fact from `GitSource.repo_binding` (the
resolved common Git directory), not a client argument. Compare it and the policy
against any persisted series before every retry lookup, including core shortcuts.
Scope/role/policy/request hashing never substitutes for that binding check. A key
reused with a different repository binding returns `CONFIGURATION_MISMATCH`; a
linked worktree with the same common directory can recover the original result.

`SubmitReview` adds `verdict`, `summary`, `recommendations`, `coverage_digest`,
`coverage` (unique change IDs acknowledging both old/new surfaces), and `carryover`.
Each finding has `severity,location,issue,suggestion`; byte maxima are respectively
the fixed enum, 150, 500, 500. Summary <=800 bytes. Each carry-over entry is
`{id,digest,status,reason}`; reason is present, at most 256 bytes and nonempty for
non-addressed entries. No original finding text is accepted in carry-over input.

Proof: the following standalone standard-library check deliberately overestimates
the maximum reachable verdict by allowing 200 prior AND 20 new findings together.
Backslashes maximize escaping under the text rule. It includes maximum-width
identities, integers, summary, reasons, coverage and MCP argument wrapping.
The verifier in Task 1 must additionally use the actual request model and existing
`jcs.canonical_bytes`; this arithmetic is a planning check, not a substitute.

```python
import json
request = dict(
    key="k"*64, expected_version=2**53-1, review_id="a"*32,
    revision_id="b"*32, snapshot_digest="c"*64, verdict="request_changes",
    summary="\\"*800, coverage_digest="d"*64,
    coverage=[f"{i:032x}" for i in range(1000)],
    recommendations=[dict(severity="important", location="\\"*150,
        issue="\\"*500, suggestion="\\"*500) for _ in range(20)],
    carryover=[dict(id="r10-"+f"{i:032x}", digest="e"*64,
        status="outstanding", reason="\\"*256) for i in range(200)])
encoded = json.dumps({"request": request}, ensure_ascii=False,
                     separators=(",", ":")).encode("utf-8")
assert len(encoded) < 256*1024, len(encoded)
print(len(encoded), 256*1024-len(encoded))
```

Before accepting new findings, policy checks `existing + new <=200`, all new-field
bounds, and the pessimistic future-ledger/maximum-coverage projection above with
the candidate history. This makes later closure representable within the verdict
payload cap. All request/response/event bytes use canonical UTF-8 for quota accounting;
binary evidence additionally charges decoded bytes once in the evidence quota and
its stored bytes once in the event/evidence total, without duplicate body copies.

Remaining metadata limits: evidence command <=2,048 bytes, runtime <=256, claimed
exit status null or signed 32-bit integer, producer fixed from configuration,
origin enum `agent_report|ci_receipt|legacy_certificate`, external URI/path <=4,096
bytes and declared length 0..2^53-1. External descriptors are never dereferenced
and always `verified=false`. Stored evidence carries computed SHA-256 and
`bytes_verified=true` but producer claims remain unverified. Inline evidence uses
strict canonical base64, maximum decoded 256 KiB; reject malformed/overlong forms.
Git path maximum is 4,096 raw bytes per path; unsupported larger paths refuse with
`LIMIT_EXCEEDED`, never normalize/truncate. Artifact pages return base64 for all
source/evidence bytes; optional UTF-8 display must not replace exact bytes.
Listing pages: at most 100 manifest/history rows AND 80 KiB canonical envelope;
the MCP result, including text/structured representations, must remain <=256 KiB.
stop at the first bound and return a continuation marker. Per-blob byte page is
<=64 KiB, including additional source-tree blobs. Never classify an empty partial
page as complete. Error detail <=1,024 bytes; never include raw bodies or secrets.
Binary-page metadata is <=4 KiB and contains IDs/digests/offsets rather than source
display text; base64 bytes avoid nested JSON escaping. History rows contain only
bounded event descriptors (ID, sequence, kind, revision, length, digest and body-
artifact ID), never inline large event bodies. Read canonical event-body bytes
through the same <=64 KiB artifact paging contract. Status returns counts and
<=200 compact finding rollups (ID, severity, disposition, digest, immutable record/
body-artifact link); prose stays in pageable history. List every nit/blocker in
the rollups without silently omitting entries.

## Task 0: Shared test-only process ownership and failure receipts

**Files:** create repository-level `tests/support/collaborative_process.py`,
`tests/support/test_collaborative_process.py`, and
`tests/support/collaborative_worker.py`, and the external command controller
`tests/support/collaborative_command.py`, which calls the same `run_case` owner,
preserves its complete/partial outcome and fails every incomplete command.
This is a test dependency, not a new
production runner. The legacy Python runner has best-effort Windows termination
and swallowed drain errors; do not reuse it as proof of this stronger contract or
change its production behavior in this feature.

**Interfaces:** standard-library-only `run_case(argv: list[str], *, cwd: Path,
environment: dict[str,str], deadline_seconds: float, expected: ExpectedExit)->CommandOutcome`
and a worker-side `OwnedTransport` implementing the SDK transport async-context
interface when the optional SDK is installed. `CommandFailure(outcome)` is typed
and always retains the partial outcome. `ExpectedExit` records the exact deliberately
injected child exit/checkpoint; default expectation is normal zero exit only.

`CommandOutcome` is a structured record with `started, completed, exit_code` (null
until actually observed), `timed_out, overflowed, cancelled`, per-channel observed/
retained counts and exact captured prefixes, `stdin_delivered`, pipe/launch errors,
termination requested/result, root reaped, tree retired, reader/writer settlement,
cleanup errors, monotonic deadline/elapsed time and expectation match. Every error
contains stage, exception type and bounded underlying detail. The capture prefix
on failure is explicitly incomplete; it can never be consumed as a successful test
result. Do not replace original exits with synthetic zero/nonzero values.
Each `stdout/stderr/control` capture is a `Capture(observed_bytes, retained_bytes,
prefix: bytes, incomplete: bool, error: StageError|None)`; `StageError` has stage,
exception type, bounded detail and cause chain. Unsupported ownership is an explicit
failed outcome, never a missing result or empty successful list.

- [ ] Write isolated probe tests first: success, launch failure, intentional exit73,
  timeout, each channel overflow, combined overflow, pipe-read/write fault,
  cancellation, direct-parent exit with a descendant holding each of stdin/stdout/
  stderr, and simulated failed retirement/cleanup. A representative assertion is:

```python
def test_inherited_pipe_is_not_success(probe_case):
    outcome = probe_case("descendant-holds-stderr", deadline_seconds=5)
    assert outcome.completed is False
    assert outcome.termination_requested
    assert outcome.root_reaped and outcome.tree_retired
    assert outcome.stderr.retained_bytes <= 4*1024*1024
```

- [ ] Implement one monotonic absolute deadline for execution **and** all teardown.
  Reserve the final 20 seconds of a normal 900-second case for cleanup (for shorter
  probes use min(20 seconds, one quarter of the total)). Every wait/join/async close/
  cancellation/fallback consumes remaining time; no fresh grace after timeout.
  The fault checkpoint's 10-second subdeadline is clipped to execution time remaining.
  Finally always attempts tree retirement and reader settlement, even after root
  exit, transport exception, output overflow or cancellation. Never close buffered
  streams under live workers; unresolved cleanup yields an incomplete outcome.
- [ ] POSIX case workers start in a fresh session/process group; retain the original
  root handle/group identity through cleanup. Windows creates the worker suspended,
  assigns it to a private kill-on-close Job Object with breakaway disabled, then
  resumes it; use standard-library ctypes Win32 bindings so dependency-install
  commands are also supervised. Set `CREATE_NO_WINDOW`. Retain job/process handles
  and query active membership until retired or the shared deadline; never rely on
  PID-only taskkill after the parent exits. POSIX sends group kill and confirms
  root wait plus group disappearance; inability to confirm is failure, not proof.
- [ ] Each case has one isolated worker owning the test scenario, its two MCP hosts
  and any fault child. New scenario subprocesses inherit that worker's group/job;
  they cannot request breakaway or create another session. On any inner fatal error,
  the external owner terminates the whole case, including driver and peers. Existing
  nested ownership used by legacy verification commands must be explicitly inventoried
  and remain controllable by the outer owner; an unregistered/escaping descendant or
  unconfirmable retirement makes the command incomplete. Never infer containment
  from the direct parent's exit or a CI job finishing.
  **Nested ownership:** only the top-level controller may create a fresh case
  group/job. A `run_case` invoked inside an owned worker inherits the same ownership
  token, absolute deadline and shared capture budget; it launches no new session/job
  and cannot extend time or retention. Its failure requests termination of the
  entire enclosing case, not local continuation. Matrix pytest workers and their
  nested stdio/fault scenarios therefore remain in the same controllable group/job.
  Keep the inherited context explicit in worker startup/control messages; absence
  or mismatch fails before spawning. Tests must reject a nested fresh-session launch.
  Run intentionally fatal supervision probes from the external controller before
  starting pytest, rather than killing an enclosing suite to test its own owner.
  Add a matrix-level-expiry probe with two inner MCP-host processes active: terminate
  the outer case and confirm pytest plus both hosts and inherited-pipe descendants
  retire. Repeat with real MCP hosts in Task 7 after the optional package exists.
- [ ] Use bounded fixed-size nonblocking pipe reads/writes. Retain at most 4 MiB
  each for stdout/stderr and 64 KiB checkpoint/control data, with an 8 MiB combined
  capture budget per owner/worker layer and 16 MiB total across both layers. Reserve
  combined capacity before appending. Crossing any per-channel/aggregate cap stops
  the case immediately; do not wait for its deadline or accept a captured prefix.
  Stdin delivery has a 1 MiB limit; control frames <=1 KiB. Reader errors trigger
  the same stop path and preserve their causes. No unbounded queues or log files.
- [ ] For real MCP children use `Client(OwnedTransport(...))`, not the SDK's implicit
  subprocess launcher: that launcher starts new POSIX sessions and has its own
  teardown policy. The test-only transport owns raw pipes, forwards SDK SessionMessage
  streams with bounded backpressure, caps each JSON-RPC frame at 512 KiB before
  parsing, accounts retained buffers with the worker budget, and consumes the
  enclosing case deadline. It does not alter production messages or server code.
  Protocol/buffer/close failures stop the case and remain structured evidence.
- [ ] Apply this same contract to base-only venv/pip commands, CLI startup/malformed
  protocol probes, both stdio peers, crash helpers, Python matrix commands and captured
  final verification commands. No direct unowned `subprocess.run`, SDK launcher or
  uncapped communicate/kill/wait remains in those new test paths. Passively running
  deterministic in-process tests need no child owner. Production host/model sessions
  remain owned by native hosts under their own policies, not by this test helper.
- [ ] Persist completed **and partial** receipts/captures create-only at each case
  boundary, including before propagating `CommandFailure`. A matrix driver keeps
  earlier outcomes if a later command fails and exits nonzero for any unexpected
  exit, startup/pipe/timeout/overflow/cancellation error or incomplete cleanup.
  An injected crash is a passed probe only when its predeclared checkpoint/exit,
  bounded capture and complete retirement all match and database recovery assertions
  pass. A normal zero exit with incomplete capture/cleanup still fails.
- [ ] Run these supervision probes on Windows/Linux/macOS before relying on any
  spawned acceptance test. Record native outcomes and capability failures. If a
  platform cannot establish the contract, stop that verification path and report
  incomplete acceptance rather than downgrade it. Commit
  `test: bound collaborative test process ownership and outcomes`.
  The matrix driver imports and calls the probe assertions in the external owner
  controller; it does not put those intentionally fatal probes inside another
  `run_case` worker. The controller never attempts recursive self-supervision.

## Task 1: Strict contracts, optional packaging and quota arithmetic

**Files:** create `collaborative/{__init__,contracts}.py`,
`tests/collaborative/{conftest,test_contracts}.py`, `tests/test_optional_install.py`;
modify `pyproject.toml`. All paths use the file-map prefix.

**Interfaces:** export frozen `OperatorConfig(repo_path: Path, state_dir: Path,
repository_id: str, source_ref: bytes, target_ref: bytes, participant: str, role: str)`,
`Policy` with the approved constants, strict Pydantic request models named
`OpenRequest, ReadRequest, EvidenceRequest, VerdictRequest, StatusRequest`, and
`CoreError(code: str, retryable: bool, detail: dict)`. Export
`encode(value: object)->bytes` wrapping existing JCS with typed error translation,
`validate_request(operation: str, payload: dict)->BaseModel`, and
`verdict_capacity(prior_count: int)->int` returning the pessimistic envelope bytes.
Export `validate_operator_config(config)->OperatorConfig`; before normalization or
resource opening it rejects a non-absolute native `repo_path` **or** `state_dir`.
CLI, GitSource, Store and direct ReviewCore construction all use that shared check.
On Windows reject drive-relative `C:repo` and root-relative `\repo`; on POSIX reject
`repo`, `./repo` and `../repo`. Unsupported network roots also fail configuration.
Use `CONFIGURATION_ERROR` for these invalid settings; never silently resolve them
against a host's current directory.
Envelope keys: `ok, assurance, review_id, revision_id, snapshot_digest,
store_version, freshness, result, error`. Freshness is `match|stale` plus checked
UTC/OIDs, `not_checked` without a new observation, or `unknown` on check failure.
Errors use the same envelope, nullable identity/version when unavailable.
Shared immutable data records are defined in `contracts.py`, rather than invented
independently by neighboring tasks:

| Type | Fields |
| --- | --- |
| `RefObservation` | source_oid, target_oid, checked_at |
| `Change` | change_id, old_path_b64/new_path_b64, old_mode/new_mode, old_oid/new_oid, old_length/new_length, old_digest/new_digest; absent sides null |
| `ArtifactHandle` | artifact_id, kind (blob/event/evidence), side (base/head or null), byte_length, sha256, mode and oid where applicable |
| `ManifestRow` | change (immutable Change), old_artifact/new_artifact (nullable ArtifactHandle); lookup handles excluded from source identity |
| `Snapshot` | header, changes (tuple of Change), digest |
| `SourceEntry` | raw_path_b64, mode, oid, length, digest, artifact_id |
| `BytePage` | data (bytes), offset, total, eof, digest |
| `Event` | id, seq, revision_id, kind, body (canonical bytes), body_digest |
| `SeriesView` | id, store_version, current_revision, snapshot, events, findings, verdict_count, revision_count, payload_bytes, evidence_bytes |
| `StoreView` | store_version, series (SeriesView or null), store_payload_bytes |
| `Mutation` | event, evidence_body (bytes or null), operation_result (canonical bytes) |
| `StoredResult` | event_id, result_bytes, store_version, replayed |
| `Page` | items, next_cursor (or null), complete, store_version |
| `AcceptedVerdict` | normalized_verdict, recommendations, carryover, coverage_digest, status |
| `Status` | series (null or compact id/current_revision), status (null before series creation), finding_rollups, counts, snapshot_digest, freshness |

Tests import `pytest`, `sys`, `dataclasses.replace` and the specific contract types
used by their snippets. `valid_open_payload` returns `{"key":"initial",
"expected_version":0}`. Remaining fixtures are defined in the tasks that introduce
their owned repository/store/policy/core dependencies.

- [ ] Create a dedicated environment only after this plan is approved. Capture a
  baseline legacy Python run before edits; record inherited failures separately.
  Install `python -m pip install -e '.[mcp,dev]'` from the package directory and
  record interpreter, platform, `pip freeze`, SQLite version and wheel provenance.
- [ ] Write these tests and the per-field/enum/unknown-key/bool/surrogate/C0/max+1
  parameter matrix. `tests/collaborative/conftest.py` begins with optional-dependency
  collection guards so a base-only environment skips this directory without import
  failure. Define the shared `cfg` fixture using a regular temporary local state
  directory and a temporary Git repository created through Dulwich.
  Add this backend fixture, matching production startup rather than parametrizing
  an uninstalled Trio backend:

```python
import pytest
pytest.importorskip("mcp")
pytest.importorskip("dulwich")
pytest.importorskip("pydantic")

@pytest.fixture
def anyio_backend():
    return "asyncio"
```

```python
def test_capacity_reserves_future_closure():
    from gauntlet_review.collaborative.contracts import verdict_capacity
    assert verdict_capacity(200) < 256*1024

def test_bool_is_not_store_version(valid_open_payload):
    import pytest
    from gauntlet_review.collaborative.contracts import validate_request, CoreError
    with pytest.raises(CoreError) as err:
        validate_request("open_review", {**valid_open_payload, "expected_version": True})
    assert err.value.code == "INVALID_ARGUMENT"
```

- [ ] Run `python -m pytest tests/collaborative/test_contracts.py -q`; first confirm
  failure due to absent contracts, then implement the models/validators/constants
  and rerun to pass. Add parameter fixtures with quotes/backslashes, TAB/CR/LF,
  U+0001 refusal, and valid four-byte Unicode; measure actual canonical bytes.
  Add shared configuration tests for POSIX relative, Windows drive-relative and
  Windows root-relative repositories/state paths. Assert `CONFIGURATION_ERROR`
  in the shared validator now. Add resource-opening entry-path regressions as each
  consumer arrives: GitSource in Task 2, Store in Task 3, ReviewCore in Task 5,
  CLI in Task 6. Each must fail before resources open.
  Execute all spawned commands below through Task 0; displayed commands specify
  inner argv, not permission to bypass the test supervisor.
- [ ] Base-only test uses a separate clean venv: install `.[dev]`, import
  `gauntlet_review` and legacy modules, assert `mcp,dulwich,pydantic` were not
  imported, and ensure new optional tests skip. The console entry point must fail
  with a short missing-extra diagnostic, not start a listener or import the model
  runtime. Add that entry point when its implementation arrives in Task 6.
- [ ] Commit the passing unit and installation contract as
  `feat: define optional collaborative review contracts`.

## Task 2: Read-only Git identity, manifests and immutable pages

**Files:** create `collaborative/source.py`, `tests/collaborative/test_source.py`;
extend the shared fixture with `GitFixture.commit(files, parents=None)->str` and
`set_ref(ref: bytes, oid: str)->None`, both test-only Dulwich object writers;
`write_worktree_file(path: str, data: bytes)->None` writes a normal fixture file.

**Interfaces:** `GitSource(config: OperatorConfig)` is a closing context manager;
`repo_binding: str` is its normalized resolved common-directory property;
`observe()->RefObservation(source_oid,target_oid,checked_at)`;
`check_snapshot(snapshot: Snapshot)->RefObservation` validates required changed
objects/types/lengths/digests and rereads configured refs;
`capture(policy: Policy)->Snapshot` with full manifest/digest;
`read_blob(oid: str, offset: int, length: int, expected_sha256: str)->BytePage`;
`source_entries(snapshot: Snapshot)->Iterator[SourceEntry]` for additional pinned
head-tree paths. `Snapshot` records repository/ref/OID/policy identity; `Change`
records raw old/new paths as base64, modes, object IDs, lengths and digests.

- [ ] Write object-level fixtures with empty files, binary/NUL, 4-byte UTF-8,
  non-UTF-8 paths, `A/a`, normalization variants, executable-bit changes,
  deletions, symlink target blobs and gitlinks. Do not create these paths in the
  host filesystem. Test normal and linked-worktree `Repo(path).commondir()` access.

```python
def test_pinned_bytes_ignore_worktree(git_fixture, cfg):
    from gauntlet_review.collaborative.source import GitSource
    from gauntlet_review.collaborative.contracts import Policy
    old = git_fixture.commit({b"file": (0o100644, b"old\x00")})
    new = git_fixture.commit({b"file": (0o100755, b"new\x00")}, parents=[old])
    git_fixture.set_ref(cfg.target_ref, old)
    git_fixture.set_ref(cfg.source_ref, new)
    with GitSource(cfg) as source:
        snap = source.capture(Policy())
        git_fixture.write_worktree_file("file", b"different")
        change = snap.changes[0]
        assert source.read_blob(change.new_oid, 0, 64, change.new_digest).data == b"new\x00"
```

- [ ] Run `python -m pytest tests/collaborative/test_source.py -q` and see the
  missing-adapter failure. Implement with `dulwich.repo.Repo`, direct object store
  access and `dulwich.diff_tree.tree_changes(..., rename_detector=None)`; never use
  porcelain, attribute normalizers, filters, shell or fetch. Close Repo on every
  path, including failed startup and exceptions.
- [ ] Validate SHA-1 repositories only in v1; reject unsupported formats/extensions,
  shallow/promisor repositories or missing required objects with typed errors.
  Traverse actual commit parents, not replace/graft interpretations. Refuse
  non-commit refs and target-not-ancestor with `NEEDS_SYNC`. Limit traversal to
  1,000,000 commits and tree inventory to 100,000 files, refusing larger work rather
  than falsely declaring complete enumeration. Include these limits in policy hash.
- [ ] Enforce source quotas before retaining the next item; count both old/new
  changed bytes even if a blob repeats, matching the declared manifest workload.
  Give deletion sides no fake empty blob. Gitlinks use their OID/mode and no blob
  byte access. Compare both refs again after capture and before its acceptance.
- [ ] Tests cover ref movement during capture, same-tree/new-commit drift, objects
  disappearing, oversized raw paths/blobs/aggregate, exhausted graph traversal,
  wrong-type objects, explicit partial pages and reader closure after exceptions.
  Compute change IDs from the canonical snapshot header and complete change record
  (SHA-256 truncated to 32 hex, with collision refusal); exclude presentation-only
  labels and opaque lookup metadata from source identity. Compute artifact IDs from
  snapshot identity, side, raw path and object OID with the same collision check.
  They are deterministic across restarts/platforms and never allocate state on read.
  Manifest API pages expose `ManifestRow` with nullable **both-side** artifact
  handles: modified files have base and head handles, deletions base only, additions
  head only, symlink blobs ordinary byte handles, and gitlinks explicit pointer
  metadata without a blob handle. Handles are lookup metadata, not additions to
  immutable Change identity. Test direct-source discovery/read-to-EOF of every side,
  including deleted paths absent from the head-tree inventory. Run equivalent
  actual MCP discovery/EOF tests after the server exists in Task 6, retained in
  the Task 7 real-stdio acceptance.
  Every source page verifies the complete object's Git identity, stored byte length
  and expected SHA-256 before returning requested bytes; a page hash is insufficient.
  A prior transaction's successful check cannot bypass current-byte validation.
  Additional file reads obey the same blob cap and snapshot identity. Missing
  garbage-collected objects fail with `MISSING_OBJECT`; never substitute worktree
  bytes. The service neither writes retention refs nor claims GC-proof availability.
- [ ] Rerun focused tests and commit `feat: read pinned collaborative Git snapshots`.

## Task 3: Transactional store, immutable history and exact retries

**Files:** create `collaborative/store.py`, `tests/collaborative/test_store.py` and
initial `test_recovery.py`; shared fixtures add transaction fault checkpoints.

**Interfaces:** `Store.open(config, repo_binding: str)->Store` (context manager),
`read_series()->SeriesView|None`, `version()->int`,
`lookup_retry(series_scope: str, participant: str, operation: str, key: str, request_digest: str)->StoredResult|None`,
`async mutate(series_scope,participant,operation,key,request_digest,expected_version,
build: Callable[[StoreView],Awaitable[Mutation]], checkpoint: Callable[[],Awaitable[None]])->StoredResult`,
and `read_page(review_id,revision_id,view,cursor,limit)->Page`.
`Mutation` contains a canonical event, evidence body bytes if any, and canonical
operation result; it is produced inside the transaction from verified state.

- [ ] Write failing transaction/reopen tests before storage code.

```python
@pytest.mark.anyio
async def test_exact_retry_precedes_stale_version(store, append_event):
    first = await append_event(store, key="once", expected_version=0)
    again = await append_event(store, key="once", expected_version=0)
    assert again.event_id == first.event_id
    assert store.version() == 1
    assert len(store.read_series().events) == 1
```

- [ ] `append_event` is a test fixture calling `Store.mutate` with a bounded
  canonical test event and an async no-op checkpoint. Test same-key/different-
  payload conflict, participant/operation scoping, restart lookup and two independent
  connections submitting from the same expected version (exactly one wins).
  Add a two-series regression with identical participant/operation/key values:
  each creates/retries independently and neither replays the other's response.
  Role/policy/request changes within a scope cannot silently replay.
  Add reused-key tests against a different common Git directory with identical
  configured repo ID/refs: both the direct lookup and mutate paths must refuse
  `CONFIGURATION_MISMATCH`. A linked worktree sharing the old common directory
  must still recover the old result without a fresh source/ref check.
- [ ] Implement strict checked startup: absolute existing state directory, no
  symlink/reparse component (`lstat`, `stat.S_ISLNK`, Windows
  `st_file_attributes & FILE_ATTRIBUTE_REPARSE_POINT`), reject redirected DB and
  `-journal/-wal/-shm` sidecars, nonregular DB, wrong permissions/access errors.
  Existing regular SQLite files are permitted. Reject state within the configured
  checkout or resolved common Git directory/legacy history; do not create parent
  directories or delete existing files. Check missing paths distinctly from denied
  access. Trusted operator ownership protects the documented non-atomic path check.
  Before each core database open, validate every intermediate state component,
  database and journal/WAL/SHM entry with platform `lstat` and Windows reparse
  flags; refuse any symlink/reparse entry and every error except genuine ENOENT.
  This is the approved cooperative non-atomic validation, not an atomic SQLite
  VFS or hostile concurrent-replacement guarantee. The core never removes a
  sidecar itself; SQLite manages its rollback journal in the validated private
  directory. Tests preserve rejected entries and existing ordinary sidecars.
- [ ] Schema v1: `meta(schema_version,store_version,payload_bytes)`,
  `series(id,repo_id,repo_binding,source_ref,target_ref,policy_digest,payload_bytes)` with unique
  repo/ref tuple; `events(id,series_id,seq,store_version,revision_id,kind,body,body_sha256)`;
  `evidence(id,series_id,revision_id,bytes,sha256)`; `retries(series_scope,participant,operation,key,
  request_sha256,event_id,result_store_version,result_bytes,result_sha256)` with composite unique key.
  Store refs as bytes; use SQL parameters exclusively. IDs are generated UUID4 hex
  and persisted, never regenerated on retry. Reject an existing series bound to a
  different resolved common Git directory or policy with `CONFIGURATION_MISMATCH`;
  never create a replacement series. Linked worktrees sharing that common directory
  use the same repository binding. Finding records are canonical event
  content; projections are rebuilt from events rather than accepted as authority.
- [ ] Use SQLite foreign keys, rollback journal `DELETE`, `synchronous=FULL`, busy
  timeout 2,000 ms, `isolation_level=None`, `BEGIN IMMEDIATE`, then persisted
  repository/policy binding validation, retry lookup, CAS version, full state
  validation, quota reservation, event/evidence/retry insert,
  version increment and COMMIT. New-file initialization also runs under the write
  lock and schema uniqueness, so two initial hosts cannot overwrite metadata.
  Read pages/status use a single read transaction and return its observed version.
  Each event additionally records its committing global store version. Before any
  replay, verify result bytes against `result_sha256`, strict decoded receipt shape,
  referenced event digest/kind, scope/revision/snapshot, request digest and exact
  committing version; it must not exceed current store version. A structurally valid
  SQLite row is insufficient. Replay checks the original receipt, not current refs.
- [ ] Logical accounting charges serialized event/result/retry bodies plus retained
  evidence bytes; deduplication cannot skip ownership/quota checks. Each admission
  checks both per-series 64 MiB and store 1 GiB inside the same transaction, plus
  the independent 16 MiB evidence quota. IDs/digests/row bookkeeping use bounded
  schema fields; the bound is not physical SQLite size. Failed reservations roll
  back every insertion and version change.
- [ ] Startup performs schema validation and SQLite integrity/foreign-key checks.
  Before deriving policy or mutating, verify the relevant series' canonical event
  digests, strict sequence, finding references and evidence digests. Refuse corruption
  or unknown schema; do not treat it as missing history or initialize over it.
  Every event-body/evidence page verifies its entire stored body's digest and bound
  series/revision/event before slicing. Every replay path, including early/core
  shortcuts, verifies the persisted receipt and event/version bindings. Add separate
  valid-JSON/raw-byte corruption tests for source, event bodies, evidence and retry
  receipts, plus wrong event/version references. Return `DIGEST_MISMATCH` or
  `CORRUPT_STATE`, never a successful payload or silently repaired history.
- [ ] Cancellation checkpoint before lock acquisition, after event construction and
  immediately before COMMIT rolls back on observed cancellation. There is no await
  between the final cancellation check and synchronous COMMIT. COMMIT is the
  linearization boundary; a lost response or cancellation after it is recovered by
  exact-key lookup. Ambiguous storage/transport failure never asserts rollback or
  successful completion. Closing cursors/connections uses `finally`, no reaper or
  recursive cleanup. Test injected exceptions before/after each insertion/commit.
- [ ] Run `python -m pytest tests/collaborative/test_store.py tests/collaborative/test_recovery.py -q`;
  confirm red then green and commit `feat: persist collaborative review history atomically`.

## Task 4: Validated findings, complete coverage and status policy

**Files:** create `collaborative/policy.py`, `tests/collaborative/test_policy.py`.

**Interfaces:** `prepare_verdict(history: SeriesView, request: VerdictRequest,
snapshot: Snapshot)->AcceptedVerdict`, `reduce_series(events: Sequence[Event])->SeriesView`,
`derive_status(history: SeriesView, observation: RefObservation)->Status`.
Reuse `gauntlet_review.verdict.recommendation_id` and JCS unchanged. Finding identity
is the pair `(review_id, finding_id)`: the immutable record and its digest bind the
review ID, and every lookup/carry-over is scoped to that review. Equal local IDs
in different reviews are allowed; cross-review records/digests must be rejected.
Test identical recommendations in two review series and cross-review carry-over.
Do not import
legacy `state.py`, broker, runtime or filesystem helpers. The new reference-ledger
contract differs from legacy text carry-over, so normalize/validate it here rather
than alter the old schema or filesystem API.

- [ ] Start with a test that an approval cannot close a disputed prior blocker.

```python
def test_disputed_blocker_remains_changes_requested(series_with_blocker, verdict_factory):
    from gauntlet_review.collaborative.policy import prepare_verdict
    req = verdict_factory(series_with_blocker, verdict="approve", disposition="disputed")
    accepted = prepare_verdict(series_with_blocker, req, series_with_blocker.snapshot)
    assert accepted.status == "changes_requested"
    assert accepted.carryover[0].reason
```

- [ ] Run the focused file to see failure, then implement exact coverage set equality
  against change IDs and complete manifest digest. For each prior finding require
  exactly one ID/digest/status/reason record, including previously addressed and nit
  findings. Reject omitted/unknown/duplicate IDs, wrong review/revision/digest,
  replacement text and invalid Unicode. Preserve original text verbatim in stored
  events and derive IDs from accepted verdict number/index/content, not revision
  count or client input. Digest the complete immutable finding record.
- [ ] Normalize approve-with-new-non-nits to request_changes. `peer_complete` is only
  a freshly observed status result with latest approval, exact coverage/carry-over
  and no unresolved non-nit. Findings marked outstanding/disputed stay open; later
  review can reopen a formerly addressed finding. Request-changes with no findings
  still requests changes. New revision removes current approval, not findings.
- [ ] Check the candidate-history projection and payload proof before accepting new
  recommendations. Include all-addressed maximum-ledger, maximal reasons, repeated
  findings, 200/201 histories, verdict 10/11, revisions 20/21, and every old/new
  blob/mode/deletion/symlink/gitlink coverage case in the tests. Avoid model mocks
  that merely echo expected policy; construct actual persisted event sequences.
- [ ] Rerun `python -m pytest tests/collaborative/test_policy.py -q` and commit
  `feat: validate collaborative findings and peer completion`.

## Task 5: Core operations and paginated audit access

**Files:** create `collaborative/core.py`, `tests/collaborative/test_core.py`;
extend shared request builders to create complete valid requests from stored IDs.

**Interfaces:** `ReviewCore(config,source,store,policy)` exposes async
`open_review(OpenRequest)`, `read_review(ReadRequest)`,
`record_evidence(EvidenceRequest)`, `submit_review(VerdictRequest)`,
`review_status(StatusRequest)`, all returning the standard envelope. It also exposes
`close()` for owned handles. Role comes only from `OperatorConfig`.

- [ ] Add a full in-process author/reviewer flow and run it red before core code.

```python
@pytest.mark.anyio
async def test_new_revision_drops_approval_not_findings(flow):
    first = await flow.open_and_submit_blocker()
    await flow.commit_fix_and_open_revision()
    status = await flow.reviewer.review_status(flow.status_request())
    assert status["result"]["status"] == "awaiting_review"
    assert status["result"]["finding_rollups"][0]["id"] == first.finding_id
```

- [ ] `flow` fixture owns two independently configured cores/connections with shared
  storage, and a test Git writer. Builders obtain observed versions from status;
  they do not bypass core validation. Implement role checks on every operation,
  validate persisted repository/policy binding before any retry shortcut,
  plus role-specific server registration later. New keys revalidate fresh refs and
  current revision inside admission; exact retries return stored results without
  pretending to recheck refs. Source capture/ref reread occurs before acceptance;
  status includes actual observation time/OIDs, not a promise against later movement.
  Status calls `source.check_snapshot` so missing/corrupt required source objects
  produce an error with unknown freshness rather than peer completion.
- [ ] Define `ReadRequest.view` enum `history|manifest|source_tree|artifact|evidence`.
  It includes bound review/revision IDs; IDs select persisted records only. For
  artifact/evidence mode include offset/length, no path. `source_tree` enumerates
  additional pinned head entries and returns deterministic opaque IDs. Resolve them
  against that pinned bounded inventory; reads never mutate storage or mint rows.
  History/manifests sort by sequence/raw path. Cursors are opaque base64 encoded
  canonical `{review_id,revision_id,snapshot_digest,view,store_version,offset}` plus
  its digest; validate every binding and integer. Digest is integrity formatting,
  not secret authentication. Reject changed-version cursor with `CONFLICT`, not
  silent page mixing; return next cursor and `complete` only at actual exhaustion.
  History descriptors link to exact pageable canonical event bodies; artifact IDs
  resolve only within the bound series/revision and collisions fail closed. Test a
  legally admitted near-limit verdict: read every history descriptor/body page,
  reconstruct exact bytes/digest and verify progress plus actual MCP size bounds.
  Exercise 200 maximal finding texts through compact status rollups and complete
  body reads; status must remain representable without concealing any finding.
- [ ] Evidence bytes and digest are committed in the same transaction as metadata;
  external descriptors stay unopened/unverified. Return `freshness.not_checked`
  for reads/replays and `unknown` on failed ref checks. Only status emits current
  `peer_complete`; mutation replies report receipt/verdict normalization, never
  current completion. On status, stale refs take precedence over approval/awaiting.
- [ ] Cover null first status, author submit refusal, reviewer open refusal,
  changed target/source refs, same-tree new commit, evidence on an old revision,
  oversized/replaced content, idempotency after drift, denied object read, quota
  refusal/reopening the same series, and source failure after stored approval.
  Error codes: `INVALID_ARGUMENT, FORBIDDEN, NOT_FOUND, NEEDS_SYNC, STALE,
  MISSING_OBJECT, UNSUPPORTED_REPOSITORY, DIGEST_MISMATCH, CONFLICT,
  LIMIT_EXCEEDED, STORAGE_ERROR, LOCK_TIMEOUT, UNSUPPORTED_SCHEMA, CORRUPT_STATE,
  INTERNAL_ERROR, CONFIGURATION_MISMATCH, CONFIGURATION_ERROR`.
  Only lock timeout, version conflict and retryable transient I/O are marked
  retryable; retries still follow exact-key semantics.
- [ ] Run `python -m pytest tests/collaborative/test_core.py -q`, then the complete
  new directory; commit `feat: expose collaborative review core operations`.

## Task 6: Thin stdio MCP adapter and safe startup

**Files:** create `collaborative/{server,__main__}.py`,
`tests/collaborative/test_server.py`; add console script to `pyproject.toml`.

**Interfaces:** `create_server(config: OperatorConfig)->Server` from
`mcp.server.lowlevel`,
`main(argv: list[str]|None=None)->int`. CLI requires `--repo`, `--state-dir`,
`--repository-id`, `--source-ref`, `--target-ref`, `--participant`, `--role`.
There are no config/env overrides for roles, quotas or arbitrary commands. Transport
is hard-coded stdio; unknown arguments fail before opening the store.

- [ ] Use the SDK's own in-memory client to test registration and structured output.

```python
@pytest.mark.anyio
async def test_reviewer_tools_exclude_open(cfg):
    from mcp import Client
    from gauntlet_review.collaborative.server import create_server
    async with Client(create_server(replace(cfg, role="reviewer")), raise_exceptions=True) as client:
        tools = await client.list_tools()
        assert {t.name for t in tools.tools} == {
            "read_review", "record_evidence", "submit_review", "review_status"}
```

- [ ] Run red, then use SDK 2.3.0 `Server(on_list_tools=..., on_call_tool=...)`
  callbacks. Advertise each input schema as a strict outer object with required
  `request` containing the corresponding Pydantic schema. The call callback receives
  raw arguments and validates outer/inner models itself, so malformed tool arguments
  get the same structured domain envelope as direct core calls. Author gets
  open/read/evidence/status; reviewer gets read/evidence/submit/status. A captured
  core enforces role even if an unregistered tool is called directly. Advertised
  input schemas must match the shared strict models; snapshot tests check fields,
  enums, additionalProperties and absence of identity/path override arguments.
- [ ] SDK imports stay inside optional modules/startup. Convert expected `CoreError`
  to safe structured envelope; unexpected exceptions return `INTERNAL_ERROR` with
  `freshness.unknown` and a correlation ID, never traceback/source/credentials on
  stdout or stderr. Return a standard `CallToolResult` with `isError=true` for
  domain errors and canonical text plus structuredContent for compatibility;
  validate its complete serialized size against the response bound. Malformed
  JSON-RPC/unrecognized protocol methods remain standard SDK protocol errors,
  never a fabricated successful core envelope.
  Log only code/operation/correlation to stderr. Never catch
  cancellation as successful result. Startup errors use stderr and exit2; success
  runs the SDK's `stdio_server()` streams and `await server.run(...)` with resource
  lifetime bound to connection
  shutdown. No remote transport is exposed even though SDK supports it.
- [ ] Test malformed startup flags, missing extra, nested extra keys, role overrides,
  raw malformed JSON/protocol failure through SDK, error parity outside MCP,
  cancellation checkpoints, context shutdown and no body leakage. Rerun
  `python -m pytest tests/collaborative/test_server.py tests/test_optional_install.py -q`.
- [ ] Commit `feat: serve collaborative review tools over local MCP`.

## Task 7: Real dual-host stdio, crash recovery and platform matrix

**Files:** create `tests/collaborative/test_stdio.py`, finish `test_recovery.py`,
create repository-level `tests/run-collaborative-matrix.py` and
`.github/workflows/collaborative-python.yml`.

- [ ] Start with a real two-client scenario in Task 0's isolated case worker.
  Import SDK `Client` and use `OwnedTransport`; each uses the exact interpreter and
  `-m gauntlet_review.collaborative` with author/reviewer config arguments.
  A test helper `server_args(cfg,role)->list[str]` emits only those declared flags.
  Task 0 owns raw pipes/groups/deadlines; SDK Client owns protocol operations, not
  an implicit subprocess. The parent pytest test calls `run_case` for this scenario
  and requires completed exit0, expectation match and full retirement. The scenario
  below runs in that supervised worker; `owned_transport` constructs Task 0's SDK
  transport using the enclosing deadline and shared capture budget.

```python
@pytest.mark.anyio
async def scenario_two_stdio_hosts_share_history(cfg, server_args, owned_transport):
    from mcp import Client
    async with Client(owned_transport(sys.executable,
            server_args(cfg, "author"))) as author, Client(
            owned_transport(sys.executable,
            server_args(cfg, "reviewer"))) as reviewer:
        initial = await reviewer.call_tool("review_status", {"request": {}})
        assert initial.structured_content["result"]["series"] is None
        opened = await author.call_tool("open_review", {"request": {
            "key": "initial", "expected_version": 0}})
        assert opened.structured_content["ok"] is True
```

- [ ] Extend that test with stored evidence, real blocker, a Git commit fix, new
  revision, full ledger closure, peer completion, then head/target drift and stale
  status. Assert native host PID differs, all original finding/evidence bytes remain
  readable after restart, and uncommitted work is never included. End all owned
  clients under Task 0's single deadline and confirm every child/tree retirement.
  Preserve original exit/capture/cleanup outcomes; unknown or partial outcomes fail.
- [ ] Fault helper runs a Store mutation in a test child, signals each checkpoint
  through a pipe and can call `os._exit(73)` immediately before or after COMMIT.
  Parent's 10s checkpoint wait consumes Task 0's execution budget; timeout stops
  the entire owned case and reaps its tree, not merely the immediate fault child.
  Preserve the structured partial outcome. Before-commit expects no
  event; after-commit exact-key retry expects one event and the original result.
  Repeat with task cancellation at precommit checkpoint and lost response after
  commit. No production `--test-crash` or fault environment switch exists.
- [ ] Test state ancestor/final-file symlinks on POSIX and Windows reparse/junction
  fixtures, regular DB reopening, redirected sidecars and permission errors. If a
  platform cannot create symlinks under current privileges, record an explicit
  unsupported fixture outcome and retain a required junction/reparse test on a
  capable Windows runner; do not call skipped security coverage verified.
- [ ] Matrix workflow: GitHub-hosted `ubuntu-latest, windows-latest, macos-latest`
  × Python `3.11,3.14,3.15`; install `.[mcp,dev]`, run new suite and legacy Python suite,
  plus a separate base-only job. No model/API secrets, CI evidence promotion or
  production setup. The Python matrix script runs these exact local suite commands,
  records interpreter/platform/dependencies and original exit codes, and provides
  Task 0 `run_case` deadlines (900s/new suite, 900s/legacy, including all cleanup).
  Nested scenario calls inherit the suite's owner/deadline/budget and never create
  an escaping process group; a nested fatal failure fails the entire suite case.
  Persist each completed/partial CommandOutcome before advancing; fail the matrix
  on unexpected exit, launch/pipe/overflow/timeout/cancellation failure or incomplete
  capture/retirement. Keep earlier outcomes after later failure. Its scope is Python
  checks only. Existing PowerShell CI stays intact.
- [ ] Run focused recovery/stdio on the current runtime, then all nine remote matrix
  jobs on publication. Locally test every installed supported interpreter available
  without inventing coverage for unavailable platforms. Commit
  `test: cover collaborative MCP recovery and platform parity`.

## Task 8: Host walkthrough, configuration and final verification

**Migration supersession:** Tasks 9–12 replace the removed conversation endpoint
and its lifecycle prohibition only for the separate SDK host adapter. All core,
evidence, native ownership, compatibility and publication constraints still apply.

**Files:** create `docs/collaborative-mcp.md` and build log, add opt-in README link.

- [ ] Document exact installation commands and a user-owned absolute Python path;
  both hosts use the same private state directory/repository/ref tuple but different
  participant IDs/roles. Include full CLI configuration examples and how to create
  the directory safely on Windows/POSIX. No new environment variable, secret,
  migration or production activation is required. An optional MCP host config is
  required only to use the feature; changing it requires host restart/reload and
  fails closed for bad paths/configuration. Never rewrite user configs automatically.
- [ ] Claude host config registers `gauntlet-author` stdio plus the separate SDK
  bridge from Tasks 9–11. The bridge configures `gauntlet-reviewer` with reviewer
  role. Show opening review, recording evidence, sending peer the IDs/manifest
  scope, `codex_status`/`codex_review` same-thread conversation, and reviewer submission. The
  walkthrough reads complete paginated source/history, treats all material as data,
  and explicitly reports coverage as reviewer attestation. Conversation transport
  success alone cannot produce peer completion.
  Document restart recovery: stop after ADAPTER_RESTARTED or thread mismatch;
  never replace the instance ID and silently replay the old request. Obtain
  explicit fresh-conversation intent, read the new status/instance, and give the
  new peer the existing review identity. Before its first verdict it must reread
  complete paginated history, every prior immutable finding body and required
  evidence/source bytes. Preserve the same series, findings and quota counters.
- [ ] Verify the packaged SDK/runtime and installed Claude interface versions against
  official docs before the Task 11 live walkthrough. Use the SDK-managed native
  lifecycle and bounded adapter waits from Task 9. Use temporary operator-owned
  host configs without copying credentials.
  Record a separately labelled live integration run on a disposable repository:
  real author/reviewer connections, one real finding/fix/closure, exact OIDs,
  tool receipts, canonical records and actual process closures. It is collaborative
  integration evidence, never legacy hermetic certification. Deterministic tests
  remain model-free and do not need API keys. Do not fake a live pass if native
  host access/credentials are unavailable; report the remaining acceptance item.
- [ ] From clean exact source, run current-runtime `pwsh -NoProfile -File tests/run-tests.ps1`,
  the legacy Python suite `python -m pytest gauntlet-review/python/tests -q`, and
  `python -m pytest gauntlet-review/python/tests/collaborative -q` with the package
  installed in the selected environment. Run the base-only install fixture;
  qualify the nine remote Python jobs after ready-PR publication in Task 12.
  Serialize owned heavy tests/reviewer calls; retain
  source hashes, original stdout/stderr/exits and closure receipts. Existing floor
  baseline failures remain scoped to unchanged dormant helpers; new active Python
  behavior must pass on its stated floor, and no dormant helper is activated.
- [ ] Add a spec-to-test acceptance table in the build log mapping each of the six
  approved acceptance paragraphs to tests/live evidence. Include quotas and the
  actual payload-proof byte result, configuration requirements, available runtime
  results, explicit skips/limitations, import isolation and `peer_complete` boundary.
  Confirm the diff has no legacy history/certificate/source integration changes.
- [ ] Commit `docs: explain collaborative MCP setup and assurance`.
- [ ] At implementation review transition, use the Human's selected local-first
  review, then one authoritative PR round. Preserve all findings through this route;
  the approved spec is the only trusted controlling document. Follow Task 12:
  finish the live gate, local fixes and verification; publish the ready PR against
  `main` as geoffroth; qualify CI; then review the exact published PR head.
  Describe optional dependencies/host configuration,
  reload behavior, local-ref freshness and all remaining limitations prominently.
  Do not approve or merge from this chat.

## Planning verification and execution handoff

## Task 9: SDK conversation adapter and locked configuration

**Files:** create `gauntlet-review/python/gauntlet_review/codex_bridge/{__init__,engine,sdk,server,__main__}.py`;
modify `gauntlet-review/python/pyproject.toml`; create
`gauntlet-review/python/tests/codex_bridge/{conftest,test_engine,test_server,test_sdk}.py`.

**Interfaces:** `BridgeConfig(operator: OperatorConfig, model: str|None=None,
timeout_seconds: int=600)`; reject timeout values outside 10–1800 seconds,
including coerced or boolean values. `PeerReply(thread_id: str, turn_id: str, text: str)`;
`Conversation.run(prompt: str) -> PeerReply`, `Conversation.close() -> None`
(async methods); `Bridge.call(request: dict) -> dict` (async),
`create_server(config) -> mcp.server.lowlevel.Server`.
`SdkConversation` implements Conversation using public Python SDK APIs. Only
the separate adapter imports the SDK. The core's five operations remain intact.

Each Bridge generates an instance ID. `codex_status` returns that ID, the owned
thread ID (nullable) and state `ready`, `busy` or `poisoned` without native work;
test each state transition. Every review request must echo the instance ID before
any cache lookup/backend call. Cache only prompt SHA-256, never prompt bodies;
count keys, digests, response bytes and metadata in total logical cache usage.
Before native work, reserve a conservative maximum cache charge for the key,
digest, metadata and largest permitted complete result (including safe errors).
Refuse admission if the total reserved plus retained charge exceeds 4 MiB; settle
the reservation to actual stored bytes after completion. Test near-cap success,
failure and lost-response replay; none may start an uncachable native turn.
The five-tool core's existing budgets remain unchanged. New errors use typed
BridgeError cause chaining and the amended spec's tagged safe failure schema.

- [ ] Write model-free engine regressions with a fake Conversation. Pin exact
  retry/continuation behavior and watch failure before implementation:

  ```python
  instance=bridge.status()["instance_id"]
  first=await bridge.call({"instance_id":instance,"key":"first","prompt":"Review pinned source","expected_thread_id":None})
  assert first["ok"] and first["thread_id"]=="fixture-thread"
  assert await bridge.call({"instance_id":instance,"key":"first","prompt":"Review pinned source","expected_thread_id":None})==first
  second=await bridge.call({"instance_id":instance,"key":"fix","prompt":"Review committed fix","expected_thread_id":"fixture-thread"})
  assert second["ok"] and second["turn_id"]!=first["turn_id"]
  assert backend.calls==2
  ```

  After instance validation, fingerprint all request fields (including nullable
  expected_thread_id) with prompt digest rather than body. Exact cache lookup
  precedes new-turn thread validation. Return the stored response unchanged;
  retry metadata does not modify it. Repeat the first key after the second turn
  and assert the original response without a third turn. Changing only
  expected_thread_id under the same key must conflict, not invoke native work.

- [ ] Add invalid/extra/coerced keys and fields, surrogate/64-KiB UTF-8 prompt,
  changed-key conflict, missing/wrong continuation ID, BUSY, 20-key/4-MiB cache,
  128-KiB full reply, backend exception, timeout/cancellation, failed cleanup and
  poisoned-state cases. Assert no unexpected extra native turn or leaked body.
  Run selected tests with `python -m pytest tests/codex_bridge -q -o addopts=`
  under `tests/support/collaborative_command.py`; expected RED for absent modules.
  Explicitly create a fresh Bridge with no owned thread and supply a prior process's
  thread ID: it must refuse before invoking its backend. Separately end/lose the
  SDK notification stream before a matching successful terminal event: response
  must fail, poison the conversation and never report success.
  Also replay the exact FIRST request against a restarted adapter: old instance
  ID must yield ADAPTER_RESTARTED uncertainty without invoking its backend.
  A later explicitly fresh call uses the new instance, a new key and null expected
  thread; host recovery must follow Task8's reread sequence, never reset core state.
  Engine acceptance of a fresh turn alone does not certify those reads; Task11's
  independent receipt verifier tests the host recovery contract.
  Successful terminal with missing/invalid final message must fail/poison. Assert
  every external error's cause, uncertainty, unusable partial marker, IDs and
  cleanup outcome, and internal chaining of the original typed failure.
- [ ] Implement strict request/config validation, one active operation, per-process
  exact replay, fixed logical bounds and safe typed errors. A five-second cleanup
  reserve stays within the original application deadline. Native uncertain paths
  poison the conversation; exact failed replay is safe, new turns refuse. No
  automatic retry, filesystem cleanup or model/config selection by clients.
  Only failures after native work may have started poison the conversation;
  invalid input, instance/thread mismatch, conflict, BUSY and pre-admission quota
  refusal leave it usable. Test an explicitly fresh call after ADAPTER_RESTARTED.
  Cancellation attempts interruption and close within the remaining original
  deadline, then propagates; test propagation and bounded cleanup independently.
  Count a cumulative maximum of 8 MiB decoded SDK-event bytes per turn; stop
  consuming immediately on the first crossed byte and interrupt/close. Test the
  exact boundary and one byte over. Apply the 256 KiB complete serialized MCP
  result limit to success, error and replay responses, including escaped text
  plus structured content, and test those paths without truncation.
- [ ] Add `codex` extra with the existing three exact optional pins plus
  `openai-codex==0.163.0`, and `gauntlet-codex` console entry point. Verify wheel
  hash and runtime dependency against the preserved PyPI/source metadata before
  installing in the isolated selected environment. Keep base-only import guards.
- [ ] Implement `SdkConversation`: lazy `AsyncCodex(CodexConfig(...))`, fixed
  reviewer MCP configuration, explicit `ApprovalMode.deny_all` and read-only
  sandbox, one `thread_start`, subsequent `thread.turn` on that object. Consume
  notifications incrementally; count decoded bytes, retain only bounded final
  message and matching terminal status. Require an item-completed agent message
  belonging to the exact owned thread and active turn; delta/started/partial items
  cannot supply final text. Test wrong-thread, wrong-turn and partial-message
  cases, including a matching successful terminal without valid final text.
  Fail on partial/failed/interrupted turn.
  Interruption/close use the SDK; no custom subprocess/JSON-RPC implementation.
- [ ] Test real SDK-shaped notifications and intercepted public SDK calls; assert
  configured tuple/role/permissions cannot be overridden, two turns share one
  thread, unrelated terminal events cannot pass, and decoded-event overflow
  interrupts. Verify complete MCP text/structured result serialization stays
  bounded and stdout contains only protocol. Run all new tests to GREEN.
- [ ] Commit `feat: connect MCP conversations through the Python Codex SDK`.

## Task 10: Native SDK and adapter qualification

**Files:** extend `tests/run-collaborative-matrix.py`,
`.github/workflows/collaborative-python.yml`,
`gauntlet-review/python/tests/test_optional_install.py`; create
`tests/support/collaborative_sdk_smoke.py` and real adapter stdio tests.

**Interfaces:** installed `.[codex,dev]`; native smoke returns SDK/runtime
version and required reviewer MCP tool names without making a model request;
all spawned verification remains inside the existing external native owner.

- [ ] Write RED cases for missing/wrong SDK/runtime pins and base-only startup;
  SDK absence cannot break existing `.[mcp]` imports or startup. Matrix optional
  jobs install `.[codex,dev]`, execute new model-free adapter tests and native
  no-model handshake/discovery. Base-only job continues to install only `.[dev]`.
- [ ] Exercise the installed SDK's packaged native runtime under the owner,
  using disposable repo/private state; preserve versions, complete stdout/stderr,
  actual exit and tree retirement. No auth copying, model request or global
  configuration rewrite. Use official SDK typed requests for any discovery;
  never implement a parallel JSON-RPC transport.
- [ ] Test adapter startup/shutdown and malformed requests with real MCP clients.
  Add externally owned cancellation/expiry cases for SDK app-server descendants.
  These certify the test run's closure, not universal SDK physical resource bounds.
- [ ] Run the complete collaborative/adapter and legacy suites on local selected
  Python environments, plus separate base-only guards. Existing PowerShell source
  is unchanged: preserve the clean b8bd4d8 whole-suite 40-file/7,281-assertion result;
  repeat it only if migration touches its exercised source. Native CI qualification
  remains required before final handoff; no Windows result implies POSIX success.
- [ ] Commit `test: qualify the SDK bridge without model credentials`.

## Task 11: Full live Claude↔Codex acceptance

**Files:** create `tests/live/collaborative-workflow.py`; update
`docs/collaborative-mcp.md`, `docs/build-log/2026-10-20-reduced-mcp-core.md`.

**Interfaces:** explicit opt-in live command, absolute create-only archive,
user-owned Claude/native Codex authentication, disposable Git repo/private state,
fixed core/bridge host configs. Native execution evidence remains separate from
Gauntlet hermetic review evidence and CI.

- [ ] Write deterministic assertions/fixtures for the acceptance verifier first:
  two accepted revisions with different committed OIDs; first non-nit finding;
  second verdict references its exact ID/digest and addresses it; evidence bytes
  match hashes; fresh status is `peer_complete`; two successful Codex turns have
  one thread ID and distinct turn IDs. Missing event/receipt/closure must fail.
  Inspect actual Claude tool receipts and typed SDK conversation history for the
  peer's core calls. Require complete manifest/source-tree/history pagination and
  all required pinned artifact/finding/evidence byte ranges through EOF, with
  lengths/digests matching canonical records for each revision. Negative fixtures
  remove a listing page, an artifact range and a prior-finding body; each must
  refuse acceptance. Coverage claims and prompt instructions alone are insufficient.
  Add a deterministic restart-recovery scenario with real persisted core state
  and receipt fixtures for the explicitly fresh conversation. Verify complete
  history pagination and every prior finding body were read before its first
  verdict, and compare the unchanged series ID, findings and counters before/after
  restart. Reject a recovery transcript missing any page/body or resetting that
  state. These model-free recovery checks do not replace the normal real live
  same-thread finding/fix/closure run.
- [ ] Create a tiny disposable committed Python fixture with an actual calculation
  defect and an explicit intended API. Start real Claude Code in print/structured
  output mode with temporary strict MCP config for author core and Codex bridge.
  Allow only the needed native tools; keep reviewer read-only/deny escalation.
  Prompts instruct complete pinned reads, source-as-data handling and core verdict
  submission. Do not tell Codex to report a predetermined finding or fake a verdict.
- [ ] Claude opens review, records evidence, requests review through the bridge,
  reads the persisted finding, fixes and commits the source, opens the next
  revision, and requests continuation on the same native Codex thread. No outer
  script fabricates model verdicts or substitutes a fake peer. The independent
  verifier reads the actual store after native processes fully retire.
- [ ] Run under one original native-owner deadline; preserve every attempt,
  full bounded transcripts, canonical records/evidence, exact OIDs/config/package
  versions and original exits/closure. Missing host auth/access leaves publication
  held with concrete diagnostics. Fix verified integration failures and repeat
  create-only; never waive this acceptance or rewrite previous reports.
- [ ] Document installation, separate console/role configuration, experimental
  runtime caveat, SDK thread lifecycle/restart limitations, cache/deadline bounds
  and absence of any automatic GitHub approval/merge. Update six-paragraph
  acceptance mapping with actual evidence only.
- [ ] Commit `docs: prove the native Claude and Codex review workflow`.

## Task 12: Local review, CI and ready PR

**2026-10-22 Human-authorized gate substitution:** After the actual complete
legacy packet was refused at its fixed character limit, the Human explicitly
authorized collaborative MCP reviews for the remaining local and PR-head gates.
Use the approved `collaborative-v1` assurance boundary, pinned committed source,
complete paginated source/history access, validated canonical findings and
carry-over, preserved native transcripts/evidence and exact PR-head/live-main
freshness checks. Multiple bounded native reading turns may precede one canonical
verdict; preserve every turn and verify their read receipts together. Preserve
all original legacy refusals/reviews and the approved spec/plan history. This
supersedes only the remaining legacy local/PR dispatch requirements below; it
does not claim legacy hermetic certification, waive CI or authorize approval or
merge. The exact direction is recorded in `collaborative-gate-authorization.json`
under the existing review history.

**Files:** preserve/append migration reviews, canonical findings, carry-over,
ledger and SHA-256 evidence indexes under the existing review history.

- [ ] Preserve original approved spec/plan blobs and all reviews. Review the
  amendment against the authorized SDK direction, then the plan against the amended
  spec using all six lenses before formal document gates. Keep original finding
  identities and dispositions; no history reset. Human's current migration directive
  and earlier native execution selection remain the controlling scope/method.
- [ ] After implementation, use one fresh whole-branch reviewer, then native local
  Gauntlet review. Fix verified defects by class with RED→GREEN evidence and a
  green suite. Do not rerun passing unchanged suites without a new reason.
- [ ] Inspect the complete review packet before dispatch. Fixed character/byte
  limits and stack-evidence gates still apply; no truncation, omitted source,
  invented premise stamps or inherited prerequisite waivers. Preserve a concrete
  refusal and escalate an actual unresolvable gate rather than bypassing it.
- [ ] Only after the live workflow passes and local review clears, push the verified
  branch as geoffroth and open a ready PR against main. Prominently document optional
  SDK/runtime dependencies, native auth/configuration, restart/reload behavior,
  experimental app-server status and fail-closed errors. No new secret or production
  migration is required; native credentials remain in their native user stores.
- [ ] Qualify all nine native matrix jobs and base-only job, fix verified CI findings,
  then complete the authoritative exact-PR-head round with live base-tip checks.
  A canonical review verdict does not authorize this chat to submit GitHub approval.
  Preserve worktree/branch/all archives for review feedback. Neither approve nor merge.

## Original planning handoff (historical)

Before implementation: commit this plan, run all six required pre-review lenses
against the approved spec, fix by class, then run the formal plan document gate with
the approved spec as its only trusted context. Preserve canonical findings, ledgers,
attempts and native receipts. Human plan approval and an execution-method choice
remain required; approval of the spec did not approve this new plan.

Recommended execution: **Native**, because source/store/policy contracts are tightly
coupled and one implementer can keep their transaction semantics consistent while
focused tests and fresh final reviews check the integrated branch. Subagent-driven
execution remains available if the human prefers per-task independent reviews.

Planning references (interface evidence, not application guarantees):
[MCP 2.3.0 release metadata](https://pypi.org/pypi/mcp/2.3.0/json),
[Dulwich 1.2.17 release metadata](https://pypi.org/pypi/dulwich/1.2.17/json),
[Pydantic 2.14.1 release metadata](https://pypi.org/pypi/pydantic/2.14.1/json),
[SDK in-process testing](https://py.sdk.modelcontextprotocol.io/get-started/testing/),
[Dulwich Repo API](https://www.dulwich.io/api/dulwich.repo.Repo.html),
[Python 3.15 final release schedule](https://peps.python.org/pep-0790/),
[AnyIO backend fixtures](https://anyio.readthedocs.io/en/stable/testing.html#specifying-the-backends-to-run-on),
[Codex MCP host example](https://developers.openai.com/cookbook/examples/codex/codex_mcp_agents_sdk/building_consistent_workflows_codex_cli_agents_sdk).
