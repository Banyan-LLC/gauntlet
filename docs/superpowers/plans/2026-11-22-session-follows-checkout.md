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
- `class Resolver(role, session_folder, state_root)`:
  - `folder(checkout)`: `None` gives the session folder. Otherwise the value must be a `str`
    whose UTF-8 encoding is at most `CHECKOUT_BYTES`, with no character below U+0020, not
    starting with `\\` or `//`, and `Path(value).is_absolute()`; anything else raises
    `BindingError("INVALID_ARGUMENT")` before any filesystem access.
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
  - `INVALID_ARGUMENT`: `checkout` must be an absolute local path or null.

Tests (`tests/collaborative/test_session.py`, reusing the `checkout` fixture pattern from
`test_launch.py`, moved into a shared helper or duplicated):
1. `resolve(None)` from a session folder on `feature/x` equals `launch.derive(...)` and the
   state directory exists and is private.
2. After `git checkout -b feature/y` in the same folder, `resolve(None)` gives the new branch
   and a different state directory; the first one is untouched.
3. `resolve(str(worktree))` binds a linked worktree; a subfolder of it binds the same tuple.
4. A session folder outside any checkout: `resolve(None)` raises `NOT_A_GIT_CHECKOUT` with
   `retryable` true; `resolve(str(checkout))` succeeds.
5. Detached HEAD raises `DETACHED_HEAD`; after `git switch -c fix/z` the same call succeeds.
6. Invalid values (`"relative/path"`, `"\\\\server\\share"`, `"//x/y"`, `"C:/a\x01b"`,
   4097 bytes, `7`, `True`) raise `INVALID_ARGUMENT` and touch nothing (no state directory,
   no log line naming the value beyond the fixed code).
7. A `_restrict` failure gives `STATE_NOT_PRIVATE`/`STATE_UNAVAILABLE`, the half-made
   directory is removed, and the log names the cleanup failure (moved from `test_launch.py`).
8. `launch.log` holds one `bind` line per tuple however many times it is resolved.

## Task 2: core session server

In `collaborative/server.py`, extract from `create_server` (behavior unchanged, existing tests
must pass untouched):
- `argument_models(extra=None)`: the strict per-tool argument models; `extra` adds optional
  top-level fields (the session server passes `{"checkout": (str | None, None)}`).
- `tool_result(payload, limit)`: builds `CallToolResult` (canonical text plus structured
  content, `is_error = not ok`) and returns `None` when over `limit`, so each caller chooses
  its own fallback. `create_server`'s `result()` uses it with its existing fallback.

In `session.py`, `create_core_server(resolver)`:
- `_require_extra()` from the collaborative server (same pins). Tools: `sorted(ROLE_TOOLS
  ["author"])`, descriptions from `DESCRIPTIONS` plus one sentence: "Optional checkout: the
  absolute path of the checkout to use (default: the session folder); every call follows
  that checkout's current branch, shown in binding."
- `_CorePool(limit=CORE_BINDINGS)`: `OrderedDict` of tuple to `[core, users]`. `acquire(t)`
  reuses (move to end, `users += 1`) or opens `GitSource(config)`, `Store.open(config,
  source.repo_binding)`, `ReviewCore(config, source, store, Policy())` with
  `OperatorConfig(t.repo, t.state_dir, t.repository_id, t.source_ref, t.target_ref,
  "claude-author", "author")`, closing the source if the store or core fails. When full, the
  least recently used entry with `users == 0` is closed first; with none, raise
  `CoreError("BUSY", retryable=True, detail={"reason": "bindings_in_use"})`. `release(t)`
  decrements. `close()` closes every core. Lifespan yields the pool and closes it.
- `call_tool`: unknown name is the existing `MCPError(INVALID_PARAMS)`. Then, in order:
  validate arguments (failure: `INVALID_ARGUMENT`, `reason: invalid_request`, binding `null`);
  resolve (failure: the code, `retryable`, `detail {"reason": "binding", "hint": ...}`,
  binding `null`); acquire (a `CoreError` gives its envelope with the binding); run the tool
  exactly as `create_server` does (`CoreError` and unexpected errors use
  `core.error_response`), release in `finally`.
- Envelope for errors without a core: the same keys `ReviewCore._envelope` produces (`ok`,
  `assurance`, `review_id`, `revision_id`, `snapshot_digest`, `store_version`, `freshness
  {"state": "unknown"}`, `result: null`, `error {code, retryable, detail}`).
- Every reply is `{**payload, "binding": binding}` through `tool_result` with
  `Policy().mcp_result_bytes`; over the limit, the `LIMIT_EXCEEDED` envelope
  (`limit: mcp_result_bytes`) with the binding.
- Server name and version as today; instructions add: "Each call follows the checkout's
  current branch. Pass checkout when you work outside the session folder and check binding.
  A branch or worktree change never needs a reconnect."

Tests (`tests/collaborative/test_session_core.py`, in-memory `mcp.Client`):
1. Tool list: the four author tools; schema properties exactly `{"request", "checkout"}`,
   `required == ["request"]`, `additionalProperties` false, `checkout` string-or-null.
2. A full status, open, record evidence, read and status cycle on `feature/x`; every reply
   has the expected `binding`, and the store directory is `launch.derive`'s.
3. Branch switch: open on `feature/x`, `git checkout -b feature/y`, status shows `series:
   null` with binding `feature/y`; switch back and the original series is still there. One
   server, no restart.
4. `checkout` to a linked worktree reviews that worktree's branch while a call without it
   still uses the session folder.
5. Session folder outside any checkout: the server starts and lists tools; a call without
   `checkout` fails with `NOT_A_GIT_CHECKOUT`, `retryable` true, a hint and `binding: null`;
   the same call with `checkout` succeeds.
6. Detached HEAD gives `DETACHED_HEAD`; after `git switch -c`, the next call succeeds.
7. Invalid `checkout` and unknown top-level keys give `INVALID_ARGUMENT`; the value never
   appears in the reply text.
8. Pool bound: with the limit monkeypatched to 2, a third binding closes the least recently
   used idle core (its `close` observed); with both in use (a stub `acquire` holder), the third
   gives `BUSY`.
9. Shutdown closes every open core.

## Task 3: peer session server

In `session.py`, `create_peer_server(resolver, timeout_seconds, extended_timeout, model=None)`:
- `_require_extra()` from the codex bridge server. `SdkConversation` is looked up through
  `gauntlet_review.codex_bridge.server.SdkConversation` at call time so tests can replace it.
- Tools: `codex_status` with schema `{"type": "object", "properties": {"checkout":
  {"anyOf": [{"type": "string"}, {"type": "null"}]}}, "additionalProperties": false}`;
  `codex_review` with `ReviewRequest.model_json_schema()` plus the same `checkout` property.
  Descriptions as today plus the checkout sentence.
- `_PeerPool(limit=PEER_BINDINGS)`: `OrderedDict` of tuple to `[bridge, users]`, plus
  `owner(instance_id)` returning the tuple whose bridge has that instance ID. `acquire(t)`
  creates `Bridge(BridgeConfig(OperatorConfig(..., "claude-peer", "reviewer"), model,
  timeout_seconds, extended_timeout), SdkConversation(config))` when absent. When full, the
  least recently used entry with `users == 0` and `bridge._busy` false is removed and
  `await bridge.close()` (the bridge's own cleanup deadline); with none, a peer error
  `LIMIT_EXCEEDED`, cause `bindings`. `close()` closes every bridge.
- `call_tool`:
  - Arguments must be an object (else `INVALID_ARGUMENT`). Split `checkout` from the rest.
  - `codex_status`: the rest must be empty (else `INVALID_ARGUMENT`). Resolve, acquire,
    `bridge.status()`, release.
  - `codex_review`: resolve. If `rest.get("instance_id")` is owned by another tuple, return
    `BINDING_CHANGED` (cause `binding_changed`) with `binding` and `instance_binding`, and
    start no turn. Else acquire, `await bridge.call(rest)` (which validates strictly and keeps
    every existing code, including `ADAPTER_RESTARTED` for an unknown instance), release.
  - Pre-bridge errors use the adapter's error shape (`code`, `cause`, `correlation_id`,
    `uncertain: false`, `partial_usable: false`, `thread_id: null`, `turn_id: null`,
    `cleanup {"status": "not_attempted", "cause": null}`) plus `hint` for binding failures.
  - Every reply goes through `engine.mcp_result({**payload, "binding": binding})`. If that
    raises `LIMIT_EXCEEDED`, the adapter's payload is returned unchanged without `binding`
    (a completed turn's text is never replaced by an error; `codex_status` shows the binding).
- Server name, version and instructions as today, plus the checkout sentence.

Tests (`tests/codex_bridge/test_session_peer.py`, fake conversation as in `test_server.py`):
1. Tool schemas: `codex_status` accepts `{}` and `{"checkout": null}`, rejects extra keys;
   `codex_review` has the request fields plus optional `checkout`.
2. Status gives an instance ID and binding without a turn; a review on that instance runs one
   turn; exact replay returns the same payload with no second turn.
3. Branch switch: status on `feature/x`, switch to `feature/y`, review with the old instance
   gives `BINDING_CHANGED` naming both bindings and no turn; status now gives a new instance
   ID bound to `feature/y`.
4. Unknown instance ID gives `ADAPTER_RESTARTED`.
5. Two checkouts (session folder and a worktree) get distinct instance IDs and conversations,
   each built with its own operator tuple.
6. Pool bound: with the limit monkeypatched to 2, a third binding closes the least recently
   used idle bridge; when both are busy the third gives `LIMIT_EXCEEDED` with cause
   `bindings`.
7. A session folder outside any checkout: status fails with `NOT_A_GIT_CHECKOUT` and a hint;
   with `checkout` it succeeds.
8. A reply that only fits without the binding is returned unchanged without it.
9. Shutdown closes every bridge.

## Task 4: launcher

`launch.main` keeps argument parsing, `check`, the absolute state root rule and the peer
timeout check. Then:
- `check_unredirected(state_root)` at startup (same codes as today).
- `_log(state_root, f"{role} session cwd={Path.cwd()}" + override)` (the override suffix as
  today, only when on).
- Build `Resolver(role, Path.cwd(), state_root)` and the session server (core or peer). A
  `StartupError` from the pin check becomes the launcher's `MISSING_EXTRA` /
  `UNSUPPORTED_EXTRA` refusal.
- `session.serve(server)`: `_safe_logging(root=True)`, then `anyio.run` over `stdio_server`,
  as the servers' `main` functions do; returns 0, 130 on `KeyboardInterrupt`.
- Remove `server_argv` and the hand-off through `sys.argv`; update the module docstring.

Tests (`tests/collaborative/test_launch.py`):
- Replace the hand-off tests with: `main` builds a session server for the right role with the
  right resolver (capture `session.serve` and the factory) and logs one `session` line.
- `main` from a folder outside any checkout now starts (no refusal) and logs `session`.
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
  `gauntlet-review/references/collaborative-review.md` (Preflight): pass `checkout` with the
  working folder when it is not the session folder; verify `binding`; a branch or worktree
  change never needs a reconnect or host reload; do not add project or local Gauntlet
  registrations; reconnect only a failed server or after a package upgrade.
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
