# Session servers that follow the checkout: implementation plan

Spec: [2026-11-22-session-follows-checkout-design.md](../specs/2026-11-22-session-follows-checkout-design.md).
Branch: `claude/gauntlet-mcp-reconnect-8ea905` (one branch for spec, plan and code, so one
review series covers the plan and PR gates).

Python paths are relative to `gauntlet-review/python`. Run tests with the MCP venv's
interpreter from that folder, so the checkout's package shadows the installed one:
`& $py -m pytest tests -q` where `$py` is the venv python (it holds the pinned extras and
pytest). PowerShell suites run with `pwsh tests/run-tests.ps1` (registration tests:
`pwsh tests/test-install-registration.ps1`).

## Task 1: binding resolver (`gauntlet_review/session.py`)

New module, stdlib-only at import time (MCP, pydantic and dulwich are imported inside the
functions that need them, as `collaborative/server.py` does).

- Constants: `CHECKOUT_BYTES = 4096`, `CORE_BINDINGS = 16`, `PEER_BINDINGS = 8`, `HINTS`
  (one fixed string per launcher code, see below), `RETRYABLE = {"NOT_A_GIT_CHECKOUT",
  "DETACHED_HEAD", "NO_TARGET_REF"}`.
- `class BindingError(Exception)`: `code`, `hint`, `retryable`.
- `class Resolver(role, state_root)` (no session folder: the server's own working folder is
  only logged, since the host may start it outside the agent's folder):
  - `folder(checkout)`: a missing value (the `MISSING` sentinel) or `None` raises
    `BindingError("INVALID_ARGUMENT", reason="checkout_required")`. Otherwise the value must
    be a `str` whose UTF-8 encoding is at most `CHECKOUT_BYTES`, with no character below
    U+0020 and no U+007F, and must be a **local absolute path in native form**, checked on the
    raw string before any filesystem access (`local_absolute(value)`):
    - Windows: with every `/` first replaced by `\`, the value must match
      `^[A-Za-z]:\\` (a drive letter, colon and root). That one rule rejects every UNC and
      device form whatever the separator mix (`\\server\share`, `//server/share`,
      `\/server/share`, `/\server\share`, `\\?\C:\x`, `\\.\pipe\x`, `\??\C:\x`), rooted paths
      without a drive (`\x`), drive-relative paths (`C:x`) and relative paths.
    - POSIX: the value must start with exactly one `/` (not `//`, which is
      implementation-defined) and contain no `\`.
    Anything else raises `BindingError("INVALID_ARGUMENT", reason="invalid_checkout")`.
  - `resolve(checkout) -> LaunchTuple`: `launch.derive(folder, state_root)`, then
    `launch.ensure_private_dir(t.state_dir, failures)`. `LaunchRefused` becomes
    `BindingError(code)`; `subprocess.SubprocessError` becomes `STATE_NOT_PRIVATE`; `OSError`
    becomes `STATE_UNAVAILABLE`; anything else becomes `INTERNAL_ERROR` with a correlation
    ID. Each refusal is logged with `launch._log(state_root, f"{role} refused {code}: {detail}
    (checkout={folder})")`. The first successful resolve of each tuple in the process logs
    `f"{role} bind checkout={t.repo} id={t.repository_id} source=... target=... state={t.state_dir}"`.
  - `public(t)`: `{"checkout": str(t.repo), "repository_id": ..., "source_ref": ...,
    "target_ref": ...}` (refs decoded UTF-8).
- Hints (fixed text, no paths):
  - `NOT_A_GIT_CHECKOUT`: pass `checkout`, the absolute path of the worktree you are working in.
  - `DETACHED_HEAD`: check out a branch (for example `git switch -c review/name`), then call
    again; no reconnect is needed.
  - `NO_TARGET_REF`: fetch origin so `refs/remotes/origin/HEAD`, `main` or `master` exists,
    then call again; no reconnect is needed.
  - `UNSUPPORTED_REF`, `UNSUPPORTED_REPOSITORY_ID`: rename the branch or origin so both are
    UTF-8 and the ID is valid.
  - `STATE_INSIDE_REPOSITORY`, `REDIRECTED_STATE_COMPONENT`, `STATE_COMPONENT_NOT_DIRECTORY`,
    `STATE_NOT_PRIVATE`, `STATE_UNAVAILABLE`: the operator's state root is unusable; see
    `launch.log`.
  - `INVALID_ARGUMENT` / `checkout_required`: pass `checkout`, the absolute path of your
    current working folder (the worktree you are working in).
  - `INVALID_ARGUMENT` / `invalid_checkout`: `checkout` must be an absolute local path.

Tests (`tests/collaborative/test_session.py`, reusing the `checkout` fixture pattern from
`test_launch.py`, moved into a shared helper or duplicated):
1. `resolve(str(checkout))` on `feature/x` equals `launch.derive(...)` and the state
   directory exists and is private.
2. After `git checkout -b feature/y` in the same folder, the same call gives the new branch
   and a different state directory; the first one is untouched.
3. `resolve(str(worktree))` binds a linked worktree; a subfolder of it binds the same tuple.
4. A folder outside any checkout raises `NOT_A_GIT_CHECKOUT` with `retryable` true.
5. Detached HEAD raises `DETACHED_HEAD`; after `git switch -c fix/z` the same call succeeds.
6. A missing value and `None` raise `INVALID_ARGUMENT` / `checkout_required`. Invalid
   values raise `INVALID_ARGUMENT` / `invalid_checkout` and touch nothing (no state
   directory, no log line naming the value beyond the fixed code). `local_absolute` is
   tested directly for both platforms (parametrized over a `windows` flag so both rule sets
   run on every OS): on Windows rules, `\\server\share`, `//server/share`, `\/server/share`,
   `/\server\share`, `\\?\C:\x`, `\\.\pipe\x`, `\??\C:\x`, `\x`, `C:x`, `relative\x` are
   refused and `C:\x`, `C:/x`, `c:\x\y` accepted; on POSIX rules, `//x/y`, `relative/x`,
   `/a\b` are refused and `/x/y` accepted. Through `folder`: also `"C:/a\x01b"`, `"\x7f"`,
   4097 bytes, `7`, `True`.
7. A `_restrict` failure gives `STATE_NOT_PRIVATE`/`STATE_UNAVAILABLE`, the half-made
   directory is removed, and the log names the cleanup failure (moved from `test_launch.py`).
8. `launch.log` holds one `bind` line per tuple however many times it is resolved.

## Task 2: core session server

In `collaborative/server.py`, extract from `create_server` (behavior unchanged, existing tests
must pass untouched):
- `argument_models(extra=None)`: the strict per-tool argument models; `extra` adds top-level
  fields (the session server passes `{"checkout": (str, ...)}`, a required string).
- `tool_result(payload, limit)`: builds `CallToolResult` (canonical text plus structured
  content, `is_error = not ok`) and returns `None` when over `limit`, so each caller chooses
  its own fallback. `create_server`'s `result()` uses it with its existing fallback.

In `session.py`, `create_core_server(resolver)`:
- `_require_extra()` from the collaborative server (same pins). Tools: `sorted(ROLE_TOOLS
  ["author"])`, descriptions from `DESCRIPTIONS` plus one sentence: "checkout (required): the
  absolute path of your current working folder; every call follows that checkout's current
  branch, shown in binding."
- `_CorePool(limit=CORE_BINDINGS)`: `OrderedDict` of tuple to `[core, users]`. `acquire` and
  `release` are synchronous (opening and closing a core never awaits), so on the single event
  loop no other call can interleave inside them; the lease is a context manager around the
  tool call, released exactly once in `finally` on success, error and cancellation.
  `acquire(t)` reuses (move to end, `users += 1`) or opens `GitSource(config)`, `Store.open(config,
  source.repo_binding)`, `ReviewCore(config, source, store, Policy())` with
  `OperatorConfig(t.repo, t.state_dir, t.repository_id, t.source_ref, t.target_ref,
  "claude-author", "author")`, closing the source if the store or core fails. When full, the
  least recently used entry with `users == 0` is closed first; with none, raise
  `CoreError("BUSY", retryable=True, detail={"reason": "bindings_in_use"})`. `release(t)`
  decrements. `close()` closes every core. Lifespan yields the pool and closes it.
- `call_tool`: unknown name is the existing `MCPError(INVALID_PARAMS)`. Then, in order:
  arguments that are an object without `checkout` give `INVALID_ARGUMENT` / `checkout_required`
  with its hint; other validation failures give `INVALID_ARGUMENT`, `reason: invalid_request`
  (binding `null` for both);
  resolve (failure: the code, `retryable`, `detail {"reason": "binding", "hint": ...}`,
  binding `null`); acquire (a `CoreError` gives its envelope with the binding); run the tool
  exactly as `create_server` does (`CoreError` and unexpected errors use
  `core.error_response`), release in `finally`.
- Envelope for errors without a core: the same keys `ReviewCore._envelope` produces (`ok`,
  `assurance`, `review_id`, `revision_id`, `snapshot_digest`, `store_version`, `freshness
  {"state": "unknown"}`, `result: null`, `error {code, retryable, detail}`).
- Every reply is `{**payload, "binding": binding}` through `tool_result` with
  `Policy().mcp_result_bytes`; over the limit, the `LIMIT_EXCEEDED` envelope
  (`limit: mcp_result_bytes`) with the binding, so no core reply ever lacks its binding.
  (The core's policy, and so its internal budgets, cannot change without changing the
  stored policy digest; the largest bounded core replies, an 80 KiB listing or a 64 KiB
  artifact page, leave far more room than a maximal binding needs, which test 10 proves.)
- Server name and version as today; instructions add: "Each call follows the checkout's
  current branch. Pass checkout (your current working folder) on every call and check
  binding. A branch or worktree change never needs a reconnect."

Tests (`tests/collaborative/test_session_core.py`, in-memory `mcp.Client`):
1. Tool list: the four author tools; schema properties exactly `{"request", "checkout"}`,
   `required == ["request", "checkout"]` (in either order), `additionalProperties` false,
   `checkout` a string.
2. A full status, open, record evidence, read and status cycle on `feature/x`; every reply
   has the expected `binding`, and the store directory is `launch.derive`'s.
3. Branch switch: open on `feature/x`, `git checkout -b feature/y`, status shows `series:
   null` with binding `feature/y`; switch back and the original series is still there. One
   server, no restart.
4. `checkout` to a linked worktree reviews that worktree's branch, and `checkout` to the main
   checkout reviews its own branch, from one server.
5. A server started (monkeypatched working folder) outside any checkout lists tools and
   serves calls whose `checkout` is a real checkout; a `checkout` outside any checkout fails
   with `NOT_A_GIT_CHECKOUT`, `retryable` true, a hint and `binding: null`.
6. Detached HEAD gives `DETACHED_HEAD`; after `git switch -c`, the next call succeeds.
7. A call without `checkout` (for example the old `{"request": {}}`) gives `INVALID_ARGUMENT`
   / `checkout_required` with its hint. Invalid `checkout` values and unknown top-level keys
   give `INVALID_ARGUMENT`; the value never appears in the reply text.
8. Pool bound: with the limit monkeypatched to 2, a third binding closes the least recently
   used idle core (its `close` observed); with both in use (a stub `acquire` holder), the third
   gives `BUSY`.
9. Shutdown closes every open core.
10. Size boundary: with a checkout path of the maximum length, a 65536-byte artifact page
    and a full-limit listing each return `ok` with the binding; with `mcp_result_bytes`
    monkeypatched below a reply's size, the reply is `LIMIT_EXCEEDED` and still carries the
    binding. An exact-key replay of a mutation also carries the binding.
11. A call cancelled while it holds a lease releases it: the binding is then evictable and
    shutdown closes it.

## Task 3: peer session server

In `session.py`, `create_peer_server(resolver, timeout_seconds, extended_timeout, model=None)`:
- `_require_extra()` from the codex bridge server. `SdkConversation` is looked up through
  `gauntlet_review.codex_bridge.server.SdkConversation` at call time so tests can replace it.
- Tools: `codex_status` with schema `{"type": "object", "properties": {"checkout":
  {"type": "string"}}, "required": ["checkout"], "additionalProperties": false}`;
  `codex_review` with `ReviewRequest.model_json_schema()` plus the same required `checkout`
  property. Descriptions as today plus the checkout sentence.
- Result budget with the binding included (engine change, default keeps today's behavior):
  `BridgeConfig` gains `result_reserve: int = 0`, validated as an `int` with
  `0 <= result_reserve <= RESULT_BYTES // 4`. `engine.mcp_result(payload, reserve=0)` refuses
  a result over `RESULT_BYTES - reserve`. `Bridge` passes `config.result_reserve` to every
  `mcp_result` call it makes (success, `error_response`, cached replay) and `SdkConversation`
  passes it to its own check of the final message, so a turn whose text would not fit with
  the binding fails inside the adapter, with its existing `LIMIT_EXCEEDED` codes, before it is
  cached. The explicit-tuple adapter keeps `result_reserve = 0`, so its limits and replies
  are unchanged. The session server sets, per binding, `result_reserve = 3 *
  len(_encode({"binding": public(t)})) + 64`: the binding appears once in the structured copy
  and once in the text copy, where JSON string escaping can at most double it, so three
  encoded copies bound its contribution to the serialized result.
- `_PeerPool(limit=PEER_BINDINGS)`: `OrderedDict` of tuple to `[bridge, users]`, `owner(
  instance_id)` returning the tuple whose bridge has that instance ID, a `closing` set and one
  `asyncio.Lock` that serializes **admission**. `lease(t)` is an async context manager:
  - Under the lock: an existing entry is reused (move to end, `users += 1`). Otherwise, if
    the pool is full, the least recently used entry with `users == 0` and `bridge._busy`
    false is removed from the map and moved to `closing`, and `await bridge.close()` runs
    while the lock is still held (bounded by the bridge's own cleanup deadline), then the
    bridge leaves `closing`. With no idle entry, a peer error `LIMIT_EXCEEDED`, cause
    `bindings`. Then the new bridge is created (`Bridge(BridgeConfig(OperatorConfig(...,
    "claude-peer", "reviewer"), model, timeout_seconds, extended_timeout, result_reserve),
    SdkConversation(config))`, which starts nothing) and inserted with `users = 1`. Because
    every admission holds the lock from the capacity check to the insert, overlapping calls
    can neither exceed the bound nor create two bridges for one tuple.
  - Cancellation during admission: the victim's close is shielded by the bridge (its cleanup
    runs under `CancelScope(shield=True)`); a victim whose close did not finish stays in
    `closing`, and pool shutdown closes it again. Nothing is inserted for the cancelled call.
  - The body runs outside the lock; `users -= 1` happens exactly once in `finally`, on
    success, error and cancellation (`Bridge.call` re-raises caller cancellation after its
    own cleanup).
  - `close()` takes the lock, then closes every entry and everything left in `closing`.
- `call_tool`:
  - Arguments must be an object (else `INVALID_ARGUMENT`). Split `checkout` from the rest; a
    missing one is `INVALID_ARGUMENT` / `checkout_required` with its hint.
  - `codex_status`: the rest must be empty (else `INVALID_ARGUMENT`). Resolve, then inside
    `async with pool.lease(t)`: `bridge.status()`.
  - `codex_review`: resolve. If `rest.get("instance_id")` is owned by another tuple, return
    `BINDING_CHANGED` (cause `binding_changed`) with `binding` and `instance_binding`, and
    start no turn. Else inside `async with pool.lease(t)`: `await bridge.call(rest)` (which
    validates strictly and keeps every existing code, including `ADAPTER_RESTARTED` for an
    unknown instance).
  - Pre-bridge errors use the adapter's error shape (`code`, `cause`, `correlation_id`,
    `uncertain: false`, `partial_usable: false`, `thread_id: null`, `turn_id: null`,
    `cleanup {"status": "not_attempted", "cause": null}`) plus `hint` for binding failures.
  - Every reply is `{**payload, "binding": binding}` (`binding` is `null` only when none was
    derived) through `engine.mcp_result` with the full `RESULT_BYTES`. The reserve makes this
    fit for every payload the bridge produced; if it ever does not, the reply is a bounded
    peer error `LIMIT_EXCEEDED`, cause `binding_budget`, that still carries the binding. No
    session reply is ever returned without `binding`.
- Server name, version and instructions as today, plus the checkout sentence.

Tests (`tests/codex_bridge/test_session_peer.py`, fake conversation as in `test_server.py`):
1. Tool schemas: `codex_status` requires `checkout` and rejects extra keys; `codex_review`
   has the request fields plus required `checkout`. `codex_status` with `{}` gives
   `INVALID_ARGUMENT` / `checkout_required` and creates no bridge.
2. Status gives an instance ID and binding without a turn; a review on that instance runs one
   turn; exact replay returns the same payload with no second turn.
3. Branch switch: status on `feature/x`, switch to `feature/y`, review with the old instance
   gives `BINDING_CHANGED` naming both bindings and no turn; status now gives a new instance
   ID bound to `feature/y`.
4. Unknown instance ID gives `ADAPTER_RESTARTED`.
5. Two checkouts (the main checkout and a linked worktree) get distinct instance IDs and
   conversations, each built with its own operator tuple.
6. Pool bound: with the limit monkeypatched to 2, a third binding closes the least recently
   used idle bridge; when both are busy the third gives `LIMIT_EXCEEDED` with cause
   `bindings`.
7. Concurrent admission: with the limit at 2, one idle bridge and its `close` blocked on an
   event, start two overlapping status calls for two new bindings and one for the same new
   binding, then release the event. Assert the pool never holds more than 2 entries, the
   same-binding calls share one bridge (one instance ID, one conversation built), and every
   bridge that was created is closed by shutdown.
8. Cancellation: cancel an in-flight review (fake conversation blocked on an event); the
   lease is released, the binding becomes evictable, and shutdown closes it. Cancel a call
   blocked in admission behind a slow eviction; nothing is inserted for it.
9. A `checkout` outside any checkout: status fails with `NOT_A_GIT_CHECKOUT` and a hint, and
   creates no bridge; a later status with a real checkout succeeds.
10. Size boundary, with a checkout path of the maximum length: a fake final message sized to
    the largest text the reserved budget admits returns `ok` with the binding, on the first
    call and on exact replay; one byte more fails inside the adapter with `LIMIT_EXCEEDED`
    and the reply still carries the binding; error replies carry it too. With
    `result_reserve = 0` the explicit-tuple adapter still admits the full `RESULT_BYTES`
    (unchanged behavior, `tests/codex_bridge/test_engine.py`).
11. Shutdown closes every bridge.

## Task 4: launcher

`launch.main` keeps argument parsing, `check`, the absolute state root rule and the peer
timeout check. Then:
- `ensure_private_root(state_root, cleanup_failures)` at startup: `check_unredirected`, then,
  only if the root does not exist, create that one directory (its parent must exist, else
  `STATE_UNAVAILABLE`) and restrict it with the same `_restrict`, removing it again if that
  fails, exactly as `ensure_private_dir` treats a missing root today (factor the shared
  create-restrict-or-remove step out of `ensure_private_dir` so both use it). An existing
  root is left as it is. Refusals use today's codes and stderr rules. No Git state is read.
- Then `_log(state_root, f"{role} session cwd={Path.cwd()}" + override)` (the override suffix
  as today, only when on), so the line is written even on a fresh installation and even if no
  call ever follows.
- Build `Resolver(role, state_root)` and the session server (core or peer). A
  `StartupError` from the pin check becomes the launcher's `MISSING_EXTRA` /
  `UNSUPPORTED_EXTRA` refusal.
- `session.serve(server)`: `_safe_logging(root=True)`, then `anyio.run` over `stdio_server`,
  as the servers' `main` functions do; returns 0, 130 on `KeyboardInterrupt`.
- Remove `server_argv` and the hand-off through `sys.argv`; update the module docstring.

Tests (`tests/collaborative/test_launch.py`):
- Replace the hand-off tests with: `main` builds a session server for the right role with the
  right resolver (state root, role) (capture `session.serve` and the factory) and logs one `session` line.
- `main` from a folder outside any checkout now starts (no refusal) and logs `session`.
- `main` with an absent state root (its parent present), from a folder outside any checkout,
  with `session.serve` captured so no call is made: the root now exists and is private, it
  holds only `launch.log`, and the log has exactly one `session` line. With the parent
  missing too: `STATE_UNAVAILABLE`, nothing created. With `_restrict` failing: the root is
  removed again and the code is `STATE_NOT_PRIVATE` or `STATE_UNAVAILABLE` as today.
- Timeout refusal, redirected state root, relative state root, unknown role, `check` and
  correlation-ID tests stay, adjusted only where they relied on `derive` running at startup
  (the unexpected-failure test patches the resolver factory instead).
- The `_restrict` failure tests move to Task 1's suite.

## Task 5: installer

In `mcp-registration.ps1`:
- `Find-GauntletProjectOverrides([string]$ClaudeConfig, [string[]]$Names)`: the per-project
  definitions under `projects.<path>.mcpServers`, as `@{ Project; Name; Raw }`, using the same
  strict read as `Read-GauntletUserEntries` (only a missing file means none).
- `Remove-GauntletProjectOverrides([string]$Claude = 'claude', [switch]$KeepProjectOverrides)`:
  returns `[pscustomobject]@{ Found; Removed; Left; Backup }` (project paths and names only).
  With nothing found, or with `-KeepProjectOverrides`, it changes nothing. Otherwise it saves
  every found definition with `Save-GauntletMcpBackup` (keys `<project>|<name>`) and stops
  with nothing removed if that fails; then, for each entry whose folder exists, runs
  `& $Claude mcp remove <name> -s local` with that folder as the current location (restored
  in `finally`); then reads the configuration back: `Removed` are the entries now absent,
  `Left` the rest.

In `install.ps1`: a `-KeepProjectOverrides` switch; after a successful registration, call
`Remove-GauntletProjectOverrides` and print what was removed (with the backup path) or warn
about what is left, naming project paths and the `claude mcp remove <name> -s local`
command. A throwing call is a warning, never an install failure.

Tests (`tests/test-install-registration.ps1`): the stub `claude` learns `remove <name> -s
local`, acting on `projects[<current folder, forward slashes>].mcpServers`. Cases: entries in
two existing project folders are backed up and removed and the user-scope entries are
untouched; an entry whose folder is missing is reported in `Left`; `-KeepProjectOverrides`
leaves the file byte-identical; a failed backup removes nothing; no definition text appears in
any returned string.

## Task 6: documentation and skills

- `docs/collaborative-mcp.md`: rewrite Global registration for session servers (per-call
  binding, `checkout`, `binding`, per-call refusal codes and hints, the pools, the one relaxed
  rule and why); replace "start a new session ... after checking out another branch" with the
  new behavior; describe the installer's override cleanup and `-KeepProjectOverrides`; keep
  the explicit-tuple sections as they are.
- `gauntlet-review/SKILL.md` (Essential checks 1) and
  `gauntlet-review/references/collaborative-review.md` (Preflight), scoped by route, because
  the same reference reaches author hosts and the Codex reviewer:
  - **Author session servers** (`gauntlet-core` and `gauntlet-peer` started by the launcher,
    recognizable by the `checkout` property in their discovered schemas): pass `checkout`
    with your current working folder on every call and verify `binding`. Preflight examples:
    `{"request": {}, "checkout": "<absolute working folder>"}` on core `review_status` and
    `{"checkout": "<absolute working folder>"}` on `codex_status`. A branch or worktree change
    never needs a reconnect or host reload.
  - **Fixed-tuple servers** (the reviewer core the adapter gives each Codex thread, and any
    explicit `gauntlet_review.collaborative` / `codex_bridge` registration): unchanged. Calls
    take only `request` (core) or the direct fields (adapter); never add `checkout`. Keep the
    existing `{"request": {}}` and `{}` preflight examples for this route.
  - Everyone: follow the discovered schemas over any example; do not add project or local
    Gauntlet registrations; a reconnect is only for a failed server or after a package
    upgrade.
  - The prompt an author sends the Codex peer must not tell it to pass `checkout`.
- `docs/build-log/2026-11-22-session-follows-checkout.md`: causes, evidence, design, tests.
- No em-dashes in any of these.

## Task 7: verification

- Full Python suite from `gauntlet-review/python` with the venv interpreter; no previously
  passing test may fail.
- `pwsh tests/test-install-registration.ps1`.
- Manual smoke: start `python -m gauntlet_review.launch core --state-root <scratch>` from a
  non-checkout folder through the in-memory client is covered by tests; additionally run one
  real stdio session (the MCP `Client` over stdio against the launcher module) from this
  worktree, call `review_status` with and without `checkout`, switch branches in a scratch
  clone and confirm the binding follows without a restart.
