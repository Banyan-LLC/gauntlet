# Session servers that follow the checkout

Agents kept reporting that Gauntlet was "paired with another branch or worktree" and asked
the owner to reconnect the MCP servers nearly every time a review started. The owner said
the tool was worthless if agents could not use it. The launcher log and the Claude Code
configuration showed three causes:

1. The launcher read the session folder's branch once, when the host started the server.
   Desktop worktree sessions start on `claude/<worktree>` and agents then create
   `feat/...`, so every branch change needed a reconnect. One worktree went through five
   branches this way; another session was launched 58 times.
2. The checkout was frozen too, and the host chose it. A reconnect of a worktree session
   started both servers in the repository's main checkout, on an unrelated branch, so even
   a reconnect could not bind the agent's worktree. Sessions started outside a checkout or
   on a detached HEAD got no tools at all: 201 `NOT_A_GIT_CHECKOUT` and 135
   `DETACHED_HEAD` refusals, each a dead server for a whole session.
3. Per-project `gauntlet-core`/`gauntlet-peer` entries in `~/.claude.json` pinned explicit
   tuples and took precedence over the user-scope launcher. Claude Code resolves a linked
   worktree's local scope to its main repository's entry, so one entry pinned every
   worktree session of this repository to `main`. Those entries (three projects) were
   backed up privately and removed with the owner's approval before any code changed.

## Change

`gauntlet_review.launch core|peer` now starts a session server
(`gauntlet_review/session.py`) whose only fixed value is the state root. Every tool takes
a required `checkout` (the agent's current working folder), and each call derives its
binding from that folder with the unchanged `launch.derive`: the same checkout, refs,
repository ID and state directory names as before, so existing stores are reused. Replies
carry `binding`. Binding failures are per-call errors with fixed hints, never a dead
server. `checkout` is required rather than defaulted because the host's start folder is
not the agent's: a default would silently bind the wrong checkout. It must be a local
absolute path in native form; on Windows one drive-letter rule refuses every UNC and
device form whatever the separator mix.

The core session server keeps one review core per binding in a bounded pool (16, least
recently used idle core closed first, `BUSY` when all are in use). The peer session server
keeps one adapter bridge per binding (8). Its admission is serialized by one lock, eviction
closes run as pool-owned tasks that a cancelled caller cannot abandon (`Bridge.close` marks
itself closed before awaiting, so an interrupted close could never be retried), and
shutdown waits for them. A review whose instance belongs to another binding is
`BINDING_CHANGED` and starts no turn. `BridgeConfig.result_reserve` (default 0, so the
explicit adapter is unchanged) keeps room for the binding inside the adapter's result
limit, so every peer reply carries it.

The launcher creates a missing state root privately at startup and logs one `session`
line; it refuses only a bad state root, missing pins or an out-of-range peer timeout.
`install.ps1` now backs up and removes per-project entries that override the user-scope
registration (`-KeepProjectOverrides` only reports them). The `gauntlet-review` skill and
reference tell author agents to pass `checkout` on every session-server call, check
`binding`, and never ask for a reconnect for a branch or worktree change, while keeping the
Codex reviewer's fixed-tuple calls request-only.

## Review and verification

The spec peer review was skipped at the owner's request. The plan went through two Codex
rounds: round 1 found three blocking issues (a size fallback that dropped `binding`,
unprotected pool admission across asynchronous close, mixed-separator UNC paths) and three
important ones (lease release on cancellation, a lost startup log line, unscoped checkout
guidance); round 2 confirmed all six addressed and found one important issue (eviction
cleanup lost on cancellation), fixed in implementation. Because this session's own servers
were pinned to the main checkout, the reviews ran through the same installed launcher
started in this worktree by a small local MCP client.

New tests: `tests/collaborative/test_session.py` (resolver), `test_session_core.py`,
`tests/codex_bridge/test_session_peer.py`, engine reserve cases in `test_engine.py`,
rewritten launcher `main` tests in `test_launch.py`, and override cleanup cases in
`tests/test-install-registration.ps1`.
