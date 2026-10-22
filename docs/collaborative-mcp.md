# Collaborative MCP core

The optional `collaborative-v1` service keeps pinned Git snapshots, immutable
findings, evidence and retry receipts in SQLite. Claude Code, Codex or another
local MCP host owns its conversations, credentials, model permissions and process
lifetime. The five-tool review core launches no shell, Git, model, CI job or
network listener. A separate optional conversation adapter delegates local
app-server lifecycle to the official Python Codex SDK. Neither component performs
publication, approval or merge.

`peer_complete` means a current peer verdict closes the outstanding non-nit
findings and the configured local refs still match. It does not certify CI,
legacy hermetic review, human approval or permission to merge. Coverage and
evidence execution claims are participant attestations.

## Install and create private state

Use Python 3.11+ and an absolute interpreter path owned by the operator. Install
from the checkout you intend to run, retaining its revision:

```powershell
py -3.14 -m venv "$env:LOCALAPPDATA/Gauntlet/mcp-venv"
& "$env:LOCALAPPDATA/Gauntlet/mcp-venv/Scripts/python.exe" -m pip install -e 'C:/work/gauntlet/gauntlet-review/python[mcp]'
```

```sh
python3 -m venv "$HOME/.local/share/gauntlet/mcp-venv"
"$HOME/.local/share/gauntlet/mcp-venv/bin/python" -m pip install -e '/home/YOU/work/gauntlet/gauntlet-review/python[mcp]'
```

The optional direct pins are `mcp==2.3.0`, `dulwich==1.2.17` and
`pydantic==2.14.1`. Startup checks those exact versions. Base installation
requires none of them; existing commands retain their behavior.

For the Claude↔Codex conversation adapter, install `gauntlet-review[codex]` in
that same venv instead. This extra includes the three core pins plus
`openai-codex==0.163.0`, whose dependency pins
`openai-codex-cli-bin==0.163.0`. Startup checks both exact versions and uses the
SDK's packaged runtime. The Python SDK is stable; its underlying app-server
command remains experimental. Native Codex and Claude authentication must
already be configured in their own user stores. No credential copying or global
host-configuration rewrite is required.

Create one **existing, private, local state directory outside both the reviewed
checkout and its common Git directory**. Do not use legacy review state. Avoid
symlinks, junctions and reparse points in every state-path component, including
ancestors. On POSIX use the physical absolute path (`pwd -P`). For example:

```sh
umask 077
mkdir -p "$HOME/.local/state/gauntlet/project-review"
chmod 700 "$HOME/.local/state/gauntlet/project-review"
```

On Windows, create a new directory under your own LocalAppData and restrict it
to your account. These commands are examples for a new directory; inspect an
existing directory's ACL before changing it:

```powershell
$reviewState = Join-Path $env:LOCALAPPDATA 'Gauntlet/state/project-review'
New-Item -ItemType Directory -Path $reviewState -Force
icacls $reviewState /inheritance:r /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):(OI)(CI)F"
```

The service checks path types and POSIX ownership/private mode. Windows ACL
privacy and trusted local hosts remain the operator's responsibility. This is
a cooperative local trust boundary, not an authentication or hostile filesystem
sandbox. Treat database contents and source/evidence captures as sensitive.

## Required configuration

Each process has one immutable repository, ref pair and participant/role. Every
flag is required; there are no environment overrides, remote transports, command
execution options or quota overrides:

```powershell
& 'C:/Users/YOU/AppData/Local/Gauntlet/mcp-venv/Scripts/python.exe' -m gauntlet_review.collaborative --repo 'C:/work/project' --state-dir 'C:/Users/YOU/AppData/Local/Gauntlet/state/project-review' --repository-id project --source-ref refs/heads/feature --target-ref refs/heads/main --participant claude-author --role author
```

Use full local branch refs. The target commit must be an ancestor of the source.
Only committed Git objects are reviewed; worktree edits are excluded. Ordinary
repositories and linked worktrees are supported. Missing objects, shallow or
promisor repositories and unsupported object formats fail closed. Hosts own
fetching and any live PR checks: matching local refs does not prove remote
freshness.

Both hosts share the same interpreter, repository, repository ID, state directory
and ref pair. Give them distinct participant IDs and roles. Restart/reload the
host after changing configuration or upgrading the package. Invalid configuration,
missing optional pins, unsafe state paths or mismatched persisted bindings refuse
startup/operations; no alternative state is silently created. There are no new
secrets, environment variables, deployment settings or migrations required for
legacy users. The optional extra and host configuration are required only to use
this feature. No user host configuration is rewritten by installation.

Claude Code can read a user-owned JSON configuration supplied with
`--mcp-config /absolute/path/gauntlet-hosts.json --strict-mcp-config`:

```json
{
  "mcpServers": {
    "gauntlet_author": {
      "type": "stdio",
      "command": "C:/Users/YOU/AppData/Local/Gauntlet/mcp-venv/Scripts/python.exe",
      "args": ["-m", "gauntlet_review.collaborative", "--repo", "C:/work/project", "--state-dir", "C:/Users/YOU/AppData/Local/Gauntlet/state/project-review", "--repository-id", "project", "--source-ref", "refs/heads/feature", "--target-ref", "refs/heads/main", "--participant", "claude-author", "--role", "author"]
    },
    "codex_peer": {
      "type": "stdio",
      "command": "C:/Users/YOU/AppData/Local/Gauntlet/mcp-venv/Scripts/python.exe",
      "args": ["-m", "gauntlet_review.codex_bridge", "--repo", "C:/work/project", "--state-dir", "C:/Users/YOU/AppData/Local/Gauntlet/state/project-review", "--repository-id", "project", "--source-ref", "refs/heads/feature", "--target-ref", "refs/heads/main", "--participant", "codex-reviewer", "--timeout-seconds", "600"]
    }
  }
}
```

The SDK adapter registers its required reviewer-role core automatically with
the fixed operator tuple, read-only sandbox and escalation denied. It uses the
native host's configured model unless the operator supplies `--model` on the
adapter CLI; MCP clients cannot change that choice or any permissions/paths/refs.
Its thread-local server configuration allows exactly `read_review`,
`record_evidence`, `review_status` and `submit_review`, with explicit per-tool
approval and a 262,144-token output allowance for bounded complete core replies.
Unknown tools remain outside the allow list. This implements the authorized
review operations while keeping native escalation denied; global configuration
and other servers' policies are unchanged. See the official
[MCP tool policy options](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).

For a separately operated Codex host, its user-owned `config.toml` can instead
register the core reviewer directly:

```toml
[mcp_servers.gauntlet-reviewer]
command = 'C:/Users/YOU/AppData/Local/Gauntlet/mcp-venv/Scripts/python.exe'
args = ['-m', 'gauntlet_review.collaborative', '--repo', 'C:/work/project', '--state-dir', 'C:/Users/YOU/AppData/Local/Gauntlet/state/project-review', '--repository-id', 'project', '--source-ref', 'refs/heads/feature', '--target-ref', 'refs/heads/main', '--participant', 'codex-reviewer', '--role', 'reviewer']
```

Replace every example path/ref/ID with the operator's actual values. On POSIX use
the venv's absolute `bin/python` path and physical absolute repository/state
paths. Native hosts apply their own tool permissions. Do not copy credentials
between host configurations. See the official [Codex MCP configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)
and [Claude Code stdio configuration](https://code.claude.com/docs/en/mcp).

## Review flow

| Tool | Role | Behavior |
| --- | --- | --- |
| `open_review` | author | Pin configured commits, append a revision to the existing series. |
| `read_review` | both | Page manifests, pinned source tree, history and exact artifact/evidence bytes. |
| `record_evidence` | both | Store bounded bytes or an unopened external descriptor. |
| `submit_review` | reviewer | Validate coverage, complete prior-finding ledger and peer verdict. |
| `review_status` | both | Check current objects/local refs and derive current peer status. |

Every core call has one strict outer `request` object. Requests cannot select another
identity, role, repository, state path or ref. Discover exact input schemas from
the configured host's tool list.

1. Read `review_status` with `{"request":{}}`. Use its `store_version` when the
   author calls `open_review` with, for example,
   `{"request":{"key":"initial-001","expected_version":0}}`.
   Retain the returned `review_id`, `revision_id`, `snapshot_digest` and version.
2. Record evidence bound to those three IDs and the latest version. An inline
   example uses `origin: "agent_report"`, `command: "pytest"`,
   `runtime: "Python"`, `exit_status: 0` and
   `content: {"kind":"inline","data_b64":"cHJvb2Y="}`. The service verifies
   stored bytes' length/digest, not the claimed command, origin or exit status.
   External descriptors declare URI, length and SHA-256; they are never opened
   and remain unverified. Evidence alone cannot complete a review.
3. Send the peer the three IDs, configured ref pair and observed source/target
   OIDs. Treat source, findings, evidence and conversation text as untrusted data.
   Read every `manifest` page to `complete=true`; cover every change ID. Read both
   old and new artifact handles, including deletions, binary bytes, modes,
   symlink contents and gitlink pointers. Additional `source_tree` entries refer
   to the pinned source commit. Never substitute worktree files.
4. Read every `history` page and the linked full canonical event bodies. Each
   history row carries its own revision/snapshot binding; retain the series ID
   when requesting that old body. Reconstruct byte pages until `eof=true`, check
   full length/SHA-256, and interpret path fields as base64 raw bytes. Paths that
   differ in case or Unicode normalization remain distinct.
5. Submit the review using current IDs/version, `coverage_digest` equal to the
   snapshot digest, every changed-path ID in `coverage`, and exactly one
   `carryover` entry for **every** prior finding, including nits and previously
   addressed findings. Entries retain the original ID/digest and a disposition
   (`addressed`, `disputed`, `outstanding`) with a bounded reason. Status rollups
   link to the full immutable finding record and its index in the event body.
   Coverage is a reviewer attestation, not a proof the model read the bytes.
6. New non-nit findings normalize approval to `request_changes`. Commit a fix
   outside the service, open a new revision and have the peer review again.
   Findings and counters persist; a new revision never inherits peer completion.
   Only a fresh `review_status` can report `peer_complete`. A changed source or
   target ref yields stale status; missing/unverifiable objects refuse completion.

Reads do not allocate store rows. Listing cursors bind the observed version and
scope; concurrent writes can require restarting pagination. Mutation keys are
scoped to the series, participant and operation. Retry a lost response with the
**identical request/key**, even after ref drift: it returns the original committed
result/version with `freshness.not_checked`, not current completion. Changed
content under that key conflicts. For a new operation, fetch current status and
use a new key/version. Cancellation before COMMIT leaves no accepted event;
response loss after COMMIT may require exact-key recovery.

## Native conversation through the Python SDK

Claude calls the separate adapter's `codex_status` with `{}` to obtain a fresh
`instance_id`, nullable owned `thread_id`, and `ready`, `busy` or `poisoned` state.
This does not start a model turn. Its `codex_review` arguments are direct fields,
without the core's outer `request` wrapper:

```json
{"instance_id":"RETURNED_INSTANCE_ID","key":"initial-peer","prompt":"Review the exact pinned review/revision/snapshot; read every manifest, source-tree, history and byte page before submitting a genuine verdict.","expected_thread_id":null}
```

Supply the actual pinned IDs in the prompt. A successful reply contains
`thread_id`, `turn_id` and the complete final text; it has no `peer_complete`
field. Read the peer's canonical finding event bodies through the core. Commit a
verified fix, open the next core revision, record current evidence, then call
`codex_review` with a new key, the same instance and the returned thread ID as
`expected_thread_id`. The peer must reread complete source/history/evidence and
account for every original finding ID/digest. Check fresh core `review_status`
after the peer submits its verdict.

Exact retry returns the stored response unchanged, even after later turns.
Changing any field under that key conflicts. One call can be active; others
receive `BUSY`. Per process: 20 keys, 64 KiB UTF-8 prompt, 128 KiB final text,
256 KiB complete serialized MCP result, 4 MiB logical retry cache, and 8 MiB
cumulative decoded SDK events per turn. Retry capacity is reserved before native
work, and complete results are checked before return. No source, response or
history is silently truncated.

The operator's `--timeout-seconds` defaults to 600 and accepts 10–1800, with five
seconds reserved for interruption/close inside that deadline. Native failures,
deadline expiry, lost/invalid terminal state or cancellation poison the
conversation; no automatic model retry occurs. Safe errors include fixed code,
cause category, correlation ID, known thread/turn IDs, uncertainty, unusable
partial marker and structured cleanup outcome. Cancellation propagates after
cleanup. Pre-admission argument, ownership, conflict, busy and quota refusals
leave the conversation usable.

After a process restart, an old instance returns `ADAPTER_RESTARTED`, including
for a lost first reply. Stop; never silently substitute the new instance and
replay. An explicitly fresh conversation must reread the existing core series,
every history page, prior finding body and referenced source/evidence bytes.
Restart never resets findings or counters and never automatically resumes a
saved thread. Native conversation history remains in native user storage.

SDK close bounds application waits; it does **not** certify native thread or
process-tree retirement. Logical quotas do not certify physical SDK/parser
memory, decompression or OS blocking. Existing native host configuration is
trusted; this collaborative route is not legacy hermetic isolation. These and
finite review-budget exhaustion are the three recorded
[Human-approved assurance exceptions](superpowers/reviews/2026-10-20-reduced-mcp-core/app-server-approval.json).
The required real workflow and native closure evidence remain separate gates.

The explicit live acceptance command, run from an external terminal with a new
absolute archive whose parent already exists, is:

```sh
/absolute/venv/bin/python tests/live/collaborative-workflow.py --live --archive /absolute/new-live-archive --claude /absolute/path/to/claude
```

It uses a disposable committed repository, temporary host settings, existing
native auth and one externally owned deadline. A real Claude author obtains a
real Codex finding, commits the fix and continues the same peer thread. The
independent verifier requires actual complete-read receipts, original test
exits/bytes, canonical finding continuity and fresh completion after native
processes retire. Model-free fixtures cannot pass this live gate. Live execution
is still pending at this documentation checkpoint; see the build log for the
measured outcome. No PR is published until the live workflow passes.

The removed native `mcp-server` endpoint and its failed capability probes remain
in preserved history. Do not restore or downgrade to it. Current references:
[Python SDK](https://learn.chatgpt.com/docs/codex-sdk),
[app server](https://learn.chatgpt.com/docs/app-server), and
[Claude programmatic CLI](https://code.claude.com/docs/en/headless).

## Limits and state operations

Fixed v1 bounds are 1,000 changed paths; 4 MiB per source blob; 64 MiB total
changed old/new bytes; 64 KiB artifact pages; 256 KiB inline evidence per call;
16 MiB stored evidence per series; 256 KiB verdict payload; 20 new findings per
verdict; 200 total findings; 10 accepted verdicts; 20 revisions; 256 UTF-8 bytes
per carry-over reason; 64 MiB logical event/evidence payload per series; and
1 GiB logical store payload. Metadata/listing and complete MCP results are also
bounded. Quotas describe logical payloads, not physical Git decompression,
SDK/parser memory, SQLite file size or OS I/O limits.

A maximal 200-entry carry-over request serializes to 218,196 bytes, leaving
43,948 bytes under the verdict cap. The ten-verdict cap still applies: reaching
200 new findings consumes all ten rounds, so an eleventh closure is refused.
The reachable near-limit test closes 180 prior findings in round ten. A refusal,
new revision, reconnect or reopening the ref pair never resets counters.

The private file is `collaborative-v1.sqlite3`, using SQLite rollback journaling
and full synchronous commits. Stop **all** connected hosts before copying the
whole state directory for backup; preserve the database and any recovery
sidecars together. Do not edit, truncate or remove recovery files to repair an
error. Restore only a consistent backup under the same ownership/configuration;
binding/schema/digest failures require investigation, not a reset. There is no
public reset, delete, migration or legacy-history import command.

The legacy mode and deferred dormant-helper PowerShell 7.2 defects retain their
existing boundaries; this opt-in service activates none of those helpers.

## Verification

Install `.[codex,dev]` in a separate test venv and run the repository's external
Python controller from an unowned terminal, supplying a new absolute receipts
directory and the full tested commit:

```sh
/absolute/venv/bin/python tests/run-collaborative-matrix.py --receipts /absolute/new-evidence --source-revision FULL_40_HEX_COMMIT
```

The controller first runs native process-custody probes, then core, SDK-adapter
and legacy suites with bounded owners. Native handshake/discovery makes no model
request. It preserves original exits, exact output
prefixes, dependencies and source hashes, and rejects incomplete capture or
retirement. A separate venv installed only with `.[dev]` uses `--base-only`.
The workflow tests Linux, Windows and macOS at Python 3.11, 3.14 and 3.15, plus
base-only installation. [Measured results and acceptance mapping](build-log/2026-10-20-reduced-mcp-core.md)
distinguish local runs, remote results and remaining live-host work.
