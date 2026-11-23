# Operator-selected peer model and effort: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Codex peer runs a Gauntlet-chosen model and effort (default `gpt-6.1-sol` at
`xhigh`) that the operator can list and switch, globally or per repository, effective from the
next peer turn and reported by `codex_status` and every completed `codex_review` reply.

**Architecture:** A stdlib-only settings store (`peer_model.py`) holds the built-in default and
reads and writes `<state-root>/peer-model.json`. The adapter's `Bridge` resolves a `Selection`
per turn (fixed from CLI flags, or from the settings file for the bridge's repository ID),
checks it against Codex's catalog (`codex_bridge/catalog.py`) without starting a turn, then
passes model and effort to the SDK turn. Operator subcommands (`model_cli.py`) behind
`python -m gauntlet_review.launch models|model` list and change the settings; a user-only
`/gauntlet-model` skill runs them.

**Tech Stack:** Python 3.14 (MCP venv), `openai-codex` 0.163.0 SDK, `mcp` 2.3.0, `dulwich`,
pytest with anyio; PowerShell 7 for the installer.

**Spec:** [2026-11-22-peer-model-selection-design.md](../specs/2026-11-22-peer-model-selection-design.md)
(approved). Read it with this plan.

Python paths are relative to `gauntlet-review/python`. Run tests from that folder with the MCP
venv interpreter so the checkout's package shadows the installed one:
`$py = 'C:/Users/geoff/.local/share/gauntlet/mcp-venv/Scripts/python.exe'`, then
`& $py -m pytest tests -q -p no:cacheprovider`. Baseline before this work: see Task 9 (one
pre-existing failure in `tests/codex_bridge/test_live_driver.py` is recorded there and is not
this work's to fix).

## Global Constraints

- Built-in default: `DEFAULT_MODEL = "gpt-6.1-sol"`, `DEFAULT_EFFORT = "xhigh"`.
- Settings file: `<state-root>/peer-model.json`, version `1`, at most 64 KiB and 256
  repository entries; entries hold `model`, `effort` or both, never neither.
- Rules: model `[A-Za-z0-9_./:-]{1,128}`, effort `[a-z]{1,32}`, repository key
  `[A-Za-z0-9_-]{1,64}` (the launcher's `ID_RE`).
- Per-field resolution: repository field, else global field, else built-in; sources
  `repository`, `global`, `built_in`, and `operator` for fixed CLI flags.
- New adapter codes: `MODEL_SETTINGS_INVALID` (cause `model_settings`), `MODEL_UNAVAILABLE`,
  `EFFORT_NOT_SUPPORTED`, `CATALOG_UNAVAILABLE` (cause `model_check`); all four are certain
  (`uncertain: false`), poison nothing and are never cached.
- CLI refusal codes: `CONFIGURATION_ERROR`, `UNKNOWN_MODEL`, `EFFORT_NOT_SUPPORTED`,
  `CATALOG_UNAVAILABLE`, `MODEL_SETTINGS_INVALID`, `NOT_A_GIT_CHECKOUT`, `MISSING_EXTRA`,
  `UNSUPPORTED_EXTRA`, plus the launcher's state-root codes; one `CODE: message` line on
  stderr, exit 2; a refused change writes nothing.
- No MCP tool changes the setting. The `/gauntlet-model` skill has
  `disable-model-invocation: true` and no `allowed-tools`.
- `BridgeConfig` keeps its existing positional order; new fields are appended (the session
  fix constructs it positionally).
- No em-dashes in docs, skill text, commit messages or PR text. Commits as
  `geoffroth <geoffroth@gmail.com>`.

## Review Focus

1. **A hand-edited settings file saved with a UTF-8 BOM** (Windows editors): it should load
   like any other. Task 1 decodes with `utf-8-sig` and tests it.
2. **A repository ID typed with capitals or underscores** (`Banyan-LLC-Gauntlet`): launcher IDs
   are lowercase slugs, so such an override would never match. Task 6 refuses an
   `--repository-id` that is not already a slug, naming `--repo` as the way to derive it.
3. **A model typed as Codex displays it** (`GPT-6-Sol`) **or an effort in capitals**
   (`XHIGH`): the operator expects it to work. Task 6 matches the catalog's model slug
   case-insensitively and stores the catalog's spelling, and lowercases efforts before the
   rule check.
4. **`--repo` given a subfolder or a linked worktree:** it should name the same repository as
   the main checkout. Task 6 tests both.
5. **A fresh install with no state root yet:** `models` and `model` (show) should report the
   built-in default and create nothing. Task 6 tests that the root is still absent afterwards.

---

### Task 1: Settings store (`gauntlet_review/peer_model.py`)

**Files:**
- Create: `gauntlet_review/peer_model.py`
- Test: `tests/test_peer_model.py`

**Interfaces:**
- Consumes: `launch.check_unredirected`, `launch.ensure_private_dir`, `launch.LaunchRefused`,
  `launch.REPARSE_POINT`, `launch._log` (imported inside functions to keep import cheap).
- Produces:
  - constants `DEFAULT_MODEL`, `DEFAULT_EFFORT`, `SETTINGS_NAME = "peer-model.json"`,
    `SETTINGS_BYTES = 64 * 1024`, `MAX_REPOSITORIES = 256`, `FIELDS = ("model", "effort")`,
    compiled `MODEL_RE`, `EFFORT_RE`, `REPOSITORY_RE` (all `fullmatch` rules above).
  - `class SettingsError(Exception)` with `.code: str` and `.detail: str` (detail is for the
    CLI's message and logs only; adapters never echo it). `load` raises code
    `MODEL_SETTINGS_INVALID`; `save` raises code `CONFIGURATION_ERROR` for a candidate beyond the
    limits (the CLI's existing code for a change it refuses).
  - `read_regular_nofollow(path: Path, limit: int) -> bytes | None`: `None` when the file does
    not exist; refuses at open time (never by a separate earlier stat) anything that is not a
    regular file, so a link, junction, reparse point, directory or FIFO swapped in at any moment
    is refused and never blocks. Raises `SettingsError` (code `MODEL_SETTINGS_INVALID`).
  - `@dataclass(frozen=True) class Selection: model: str; effort: str; model_source: str;
    effort_source: str` with `public() -> dict` returning exactly
    `{"model", "model_source", "effort", "effort_source"}`.
  - `@dataclass(frozen=True) class Settings: default: Mapping[str, str];
    repositories: Mapping[str, Mapping[str, str]]` (store `MappingProxyType` copies).
    `EMPTY = Settings({}, {})`.
  - `fixed(model: str | None, effort: str | None) -> Selection`
  - `resolve(settings: Settings, repository_id: str | None) -> Selection`
  - `load(root: Path) -> Settings`
  - `selection_for(root: Path, repository_id: str | None) -> Selection` (`resolve(load(root), id)`)
  - `with_fields(settings, repository_id: str | None, *, model: str | None = None,
    effort: str | None = None) -> Settings` (sets only the non-None fields)
  - `without_fields(settings, repository_id: str | None, fields: tuple[str, ...]) -> Settings`
    (drops an entry that becomes empty)
  - `to_document(settings) -> dict` (the version-1 JSON object, keys sorted, empty parts omitted)
  - `encode_document(settings) -> bytes` (UTF-8 JSON of `to_document`, `indent=2`, LF line
    endings, one trailing newline; the exact bytes `save` validates and writes)
  - `save(root: Path, settings: Settings) -> None`
  - `scope_name(repository_id: str | None) -> str` (`"global"` or `"repository:<id>"`)

- [ ] **Step 1: Write the failing tests** in `tests/test_peer_model.py`:
  - `test_missing_root_or_file_is_the_built_in_default`: `selection_for(tmp_path/"absent", "r")`
    and `selection_for(tmp_path, "r")` (no file) both equal
    `Selection("gpt-6.1-sol", "xhigh", "built_in", "built_in")`, and `tmp_path/"absent"` still
    does not exist.
  - `test_fields_inherit_one_at_a_time`: file `{"version":1,"default":{"effort":"max"},
    "repositories":{"r":{"model":"gpt-6-sol"}}}` gives `("gpt-6-sol","max","repository","global")`
    for `"r"`, `("gpt-6.1-sol","max","built_in","global")` for `"other"` and for `None`.
  - `test_fixed_selection_sources`: `fixed(None, None)` is all built-in; `fixed("m", None)` is
    `("m","xhigh","operator","built_in")`.
  - `test_invalid_files_are_refused` (parametrized; each raises `SettingsError` with code
    `MODEL_SETTINGS_INVALID`): not JSON; JSON `[]`; `version` 2; missing `version`; unknown
    top-level key; unknown entry key; duplicate key at any level; `{"default":{}}`; model
    `"bad model"`; effort `"High"`; repository key `"a/b"`; 257 repositories; `NaN` value; a
    file of `SETTINGS_BYTES + 1` bytes; invalid UTF-8.
  - `test_a_bom_is_accepted`: the valid example file written with a leading UTF-8 BOM loads.
  - `test_the_open_refuses_a_link`: `peer-model.json` as a symbolic link to a valid file raises
    `SettingsError` (POSIX always; Windows when `os.symlink` is permitted, else skip).
  - `test_a_reparse_point_seen_on_the_handle_is_refused` (Windows, deterministic, no privilege):
    monkeypatch the helper's handle-attribute query to report `FILE_ATTRIBUTE_REPARSE_POINT`
    for a real regular file; `load` raises. A second case reports `FILE_ATTRIBUTE_DIRECTORY`.
  - `test_a_fifo_is_refused_without_blocking` (POSIX): `os.mkfifo` at the settings path;
    `load` raises within one second (run it in a thread with a timeout).
  - `test_a_redirected_state_root_is_refused`: the root reached through a junction
    (`_winapi.CreateJunction` on Windows, which needs no privilege) or a directory symlink
    (POSIX) raises; so does a directory named `peer-model.json`.
  - `test_save_round_trips_privately`: `save` into a missing root creates it, `load` returns
    equal settings, the destination's raw bytes equal `encode_document(settings)` exactly (no
    newline translation), no `*.tmp` file remains, and on POSIX the file mode is `0o600`.
  - `test_save_refuses_candidates_beyond_the_limits`: a 257th repository; and 256 valid
    entries (long IDs and models) whose compact form fits 64 KiB but whose written form does
    not. Each raises `SettingsError` code `CONFIGURATION_ERROR`, the existing file keeps its
    exact bytes and no `*.tmp` file remains. A candidate that fits exactly is written and loads.
  - `test_save_retries_transient_replace_failures`: `os.replace` (monkeypatched in the module)
    raises `PermissionError` twice, then succeeds: three calls, new content on disk.
  - `test_save_gives_up_after_bounded_retries`: `os.replace` always raises `PermissionError`:
    `save` raises after exactly 5 attempts, the destination keeps its original bytes, no
    `*.tmp` file remains.
  - `test_a_failed_temporary_write_keeps_the_original`: the temporary file's write raises
    `OSError`: the original bytes are intact, `os.replace` was never called, no `*.tmp` remains.
  - `test_with_and_without_fields`: `with_fields(EMPTY, "r", effort="high")` sets only
    `repositories["r"]["effort"]`; `without_fields(that, "r", ("effort",))` equals `EMPTY`;
    `without_fields(s, None, ("model",))` leaves the global effort.
- [ ] **Step 2: Run** `& $py -m pytest tests/test_peer_model.py -q`. Expected: fails on import.
- [ ] **Step 3: Implement `peer_model.py`.** Notes the tests do not pin:
  - `read_regular_nofollow`: POSIX opens with `os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK |
    os.O_CLOEXEC` (a link fails with `ELOOP`, a FIFO does not block) and requires
    `S_ISREG(fstat(fd).st_mode)`. Windows opens through `ctypes` `CreateFileW` with
    `GENERIC_READ`, share read, write and delete, `OPEN_EXISTING` and
    `FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS` (the link itself is opened, never
    its target), requires `GetFileType == FILE_TYPE_DISK` and `GetFileInformationByHandle`
    attributes without `FILE_ATTRIBUTE_REPARSE_POINT` or `FILE_ATTRIBUTE_DIRECTORY` (the
    attribute query is a module function the test can replace), then wraps the handle with
    `msvcrt.open_osfhandle`. Both read at most `limit + 1` bytes from the vetted handle and
    close it in `finally`. Not-found errors give `None`.
  - `load`: `check_unredirected(root)` (`LaunchRefused` becomes `SettingsError`); a missing
    root or file is `EMPTY`. Decode `utf-8-sig` strictly; `json.loads` with an
    `object_pairs_hook` that refuses duplicate keys and a `parse_constant` that refuses
    `NaN`/`Infinity`; validate with the same `_validate(document) -> Settings` that `save`
    uses. Any `OSError` is `SettingsError`.
  - `save`: build the document, run `_validate` on it and encode it (UTF-8, `indent=2`,
    trailing newline); refuse before touching the disk when validation fails or the bytes
    exceed `SETTINGS_BYTES`. Then `ensure_private_dir(root)`; write the bytes to
    `root / f"{SETTINGS_NAME}.{uuid4().hex}.tmp"` opened with exclusive binary mode `"xb"` and receiving exactly the validated buffer; on POSIX
    `chmod 0o600`; `os.replace` onto the target, retrying `PermissionError` up to 5 attempts
    in all, 50 ms apart (Windows readers); remove the temporary file on any failure and
    re-raise. Other `OSError`s propagate (the CLI maps them).
- [ ] **Step 4: Run** the same command. Expected: all pass.
- [ ] **Step 5: Commit** `feat: add the peer model settings store`.

### Task 2: Catalog helpers (`gauntlet_review/codex_bridge/catalog.py`)

**Files:**
- Create: `gauntlet_review/codex_bridge/catalog.py`
- Test: `tests/codex_bridge/test_catalog.py`

**Interfaces:**
- Consumes: `openai_codex.AsyncCodex.models(include_hidden=True) -> ModelListResponse`
  (fields used: `data[].model`, `.display_name`, `.is_default`, `.hidden`,
  `.default_reasoning_effort.value`, `.supported_reasoning_efforts[].reasoning_effort.value`,
  and `next_cursor`).
- Produces:
  - `@dataclass(frozen=True) class CatalogModel: model: str; display_name: str;
    catalog_default: bool; hidden: bool; default_effort: str; efforts: tuple[str, ...]`
  - `@dataclass(frozen=True) class Catalog: models: tuple[CatalogModel, ...]; complete: bool`
  - `from_response(response) -> Catalog` (`complete = response.next_cursor is None`)
  - `find(catalog, model: str) -> CatalogModel | None` (case-insensitive on `model`)
  - `check(catalog, model: str, effort: str) -> str | None`: `None` when listed and the effort
    is supported; else `"MODEL_UNAVAILABLE"` (absent from a complete catalog),
    `"CATALOG_UNAVAILABLE"` (absent from an incomplete one), `"EFFORT_NOT_SUPPORTED"`.
  - `async fetch(client) -> Catalog`
  - `fetch_catalog() -> Catalog`: synchronous; `asyncio.run` over
    `async with AsyncCodex(CodexConfig()) as client: return await fetch(client)`. Raises
    whatever the SDK raises; callers map it.

- [ ] **Step 1: Write the failing tests:** build real `ModelListResponse.model_validate`
  objects (two models: `gpt-6.1-sol` with efforts `low..ultra`, `gpt-6-luna` without
  `ultra`, one hidden `codex-auto-review`).
  - `test_from_response_keeps_every_field_and_completeness` (also with `nextCursor: "c"`).
  - `test_check_answers_each_case`: `("gpt-6.1-sol","xhigh") -> None`;
    `("GPT-6.1-SOL","xhigh") -> None`; `("gpt-6-luna","ultra") -> "EFFORT_NOT_SUPPORTED"`;
    `("gpt-7","low") -> "MODEL_UNAVAILABLE"`; the same on an incomplete catalog
    `-> "CATALOG_UNAVAILABLE"`; the hidden model is found.
  - `test_fetch_asks_for_hidden_models`: a stub client records `include_hidden=True`.
- [ ] **Step 2: Run** `& $py -m pytest tests/codex_bridge/test_catalog.py -q`. Expected: fail.
- [ ] **Step 3: Implement `catalog.py`** (import `openai_codex` only inside `fetch_catalog`).
- [ ] **Step 4: Run** it again. Expected: pass.
- [ ] **Step 5: Commit** `feat: read the Codex model catalog for the peer`.

### Task 3: Engine selection, status and the per-turn check

**Files:**
- Modify: `gauntlet_review/codex_bridge/engine.py` (`BridgeError`, `BridgeConfig`,
  `validate_config`, `PeerReply`, `Conversation`, `Bridge.status`, `Bridge.call`)
- Test: `tests/codex_bridge/test_engine.py` (update the fake and two exact assertions; add tests)

**Interfaces:**
- Consumes: Task 1 (`Selection`, `fixed`, `selection_for`, `SettingsError`, `EFFORT_RE`).
- Produces:
  - `BridgeConfig(operator, model=None, timeout_seconds=600, extended_timeout=False,
    effort=None, model_settings_root=None)` (new fields appended).
  - `class ModelCheckRefusal(BridgeError)`: raised only by `Conversation.check`; code one of
    `MODEL_UNAVAILABLE`, `EFFORT_NOT_SUPPORTED`, `CATALOG_UNAVAILABLE`; cause `model_check`.
  - `PeerReply(thread_id, turn_id, text, rerouted: tuple[str | None, str | None] | None = None)`
  - `Conversation` protocol: `async check(selection) -> None`,
    `async run(prompt, selection) -> PeerReply`, `async close() -> None`.
  - `reply_payload(reply: PeerReply, selection: Selection) -> dict`: `{"ok": True,
    "thread_id", "turn_id", "text", "peer_model": {**selection.public(), "rerouted": {"to",
    "reason"}}}` with `rerouted` present only when `reply.rerouted` is set.
  - `Bridge.selection() -> Selection` (raises `BridgeError("MODEL_SETTINGS_INVALID",
    cause="model_settings")`).

- [ ] **Step 1: Update the fake and write the failing tests.** The fake `Conversation` gains
  `check(selection)` (records selections; raises a configurable `ModelCheckRefusal` or other
  exception) and `run(prompt, selection)` (records the selection). Update the existing exact
  assertions to include `"peer_model": {"model":"gpt-6.1-sol","model_source":"built_in",
  "effort":"xhigh","effort_source":"built_in"}` and the status key checks. New tests:
  - `test_status_reports_the_selection_for_each_mode`: fixed built-in; fixed `model="gpt-6-sol"`
    (`operator`/`built_in`); settings mode with a file giving repository and global sources
    for the fixture's repository ID `"fixture"`; an invalid file gives
    `{"error":"MODEL_SETTINGS_INVALID"}` with `ok` still true.
  - `test_a_switch_between_turns_reaches_the_next_turn`: settings mode; turn 1, then `save` a
    new model and effort, then turn 2; the fake saw both selections in order and each reply's
    `peer_model` names its own.
  - `test_an_invalid_settings_file_refuses_cleanly`: `refused(result, "MODEL_SETTINGS_INVALID")`,
    `peer.calls == 0`, no `check` call, state `ready`; after fixing the file the same key
    succeeds (proving nothing was cached).
  - `test_catalog_refusals_are_certain_and_recoverable` (parametrized over the three codes):
    `refused(..., code)` with `uncertain` false and cleanup `not_attempted`, `peer.calls == 0`,
    `peer.closed == 0`, state `ready`, and a retry of the same key after the fake stops
    refusing returns a completed reply in the same conversation.
  - `test_a_failing_check_poisons_as_today`: `check` raises `RuntimeError`; the reply is
    `SDK_FAILURE`, uncertain, state `poisoned`, `peer.closed == 1`.
  - `test_a_model_check_refusal_from_run_is_not_certain`: `run` raises `ModelCheckRefusal`;
    the reply is uncertain and the bridge is poisoned.
  - `test_replay_after_a_switch_returns_the_original_model`.
  - `test_configuration_refusals` (parametrized): effort `"High"`; `model_settings_root` with
    `model`; with `effort`; a relative `model_settings_root`. Each raises
    `BridgeError("CONFIGURATION_ERROR")` from `Bridge(...)`.
- [ ] **Step 2: Run** `& $py -m pytest tests/codex_bridge/test_engine.py -q`. Expected: fail.
- [ ] **Step 3: Implement.** In `call`, resolve the selection after the cache-bound check and
  before `_busy = True`; the task becomes an inner coroutine that awaits
  `conversation.check(selection)` and **returns** (does not raise) a `ModelCheckRefusal` it
  catches there, then awaits `run(prompt, selection)`. When the task result is a
  `ModelCheckRefusal`, return `error_response(refusal)` (not uncertain, cleanup not attempted)
  without poisoning, closing or caching. A `ModelCheckRefusal` raised from `run` goes through
  the existing failure path. Completed replies use `reply_payload`. `status()` adds
  `peer_model` from `selection().public()`, or the error object when it raises.
- [ ] **Step 4: Run** the engine tests. Expected: pass.
- [ ] **Step 5: Commit** `feat: resolve and check the peer model for every turn`.

### Task 4: SDK conversation

**Files:**
- Modify: `gauntlet_review/codex_bridge/sdk.py`
- Test: `tests/codex_bridge/test_sdk.py`, `tests/codex_bridge/test_sdk_stream_cleanup.py`

**Interfaces:**
- Consumes: Task 2 (`catalog.from_response`, `catalog.check`), Task 3 (`ModelCheckRefusal`,
  `PeerReply.rerouted`, `reply_payload`), Task 1 (`Selection`, `MODEL_RE`).
- Produces: `SdkConversation.check(selection)`, `SdkConversation.run(prompt, selection)`.

- [ ] **Step 1: Update the fakes and write the failing tests.** `Native.turn(prompt, **options)`
  records options; `Native.models(include_hidden)` returns a configurable
  `ModelListResponse` or raises; `Native.__aenter__()` counts calls and can raise. Every existing `peer.run("…")` call passes
  `SELECTION = Selection("gpt-6-sol","high","global","global")`. Change the assertion
  `options["model"] is None` to `== "gpt-6-sol"`. New tests:
  - `test_every_turn_receives_the_model_and_effort`: two turns with different selections;
    `native.turn_options[n]["model"]` and `["effort"]` (a `ReasoningEffort` whose `.value` is
    the selection's effort) match each turn; `thread_start` saw only the first model.
  - `test_check_answers_from_the_catalog` (parametrized): listed pair passes; unknown model is
    `ModelCheckRefusal("MODEL_UNAVAILABLE")`; unsupported effort is `EFFORT_NOT_SUPPORTED`; an
    incomplete catalog without the model and a `JsonRpcError` are `CATALOG_UNAVAILABLE`; a
    `TransportClosedError` propagates as a non-refusal `BridgeError("SDK_FAILURE")`. `check`
    asked with `include_hidden=True` and initialized the client only once across calls.
  - `test_an_initialize_failure_is_not_a_catalog_refusal`: through a real `Bridge` over
    `SdkConversation`, `Native.__aenter__` raises `JsonRpcError` on the first check. The reply
    is `SDK_FAILURE`, `uncertain: true`, state `poisoned`, no turn was started, cleanup ran
    (`native.closed`), and an exact replay of the same key returns the identical cached
    payload. A separate case, initialization succeeding and `models` raising `JsonRpcError`,
    stays the recoverable `CATALOG_UNAVAILABLE`.
  - `test_a_matching_reroute_is_reported`: a `model/rerouted` notification
    (`ModelReroutedNotification`, same thread and turn, `toModel` `gpt-6-luna`, reason
    `highRiskCyberActivity`) before the terminal gives `reply.rerouted ==
    ("gpt-6-luna","highRiskCyberActivity")`; a foreign turn's notification gives `None`.
- [ ] **Step 2: Run** `& $py -m pytest tests/codex_bridge/test_sdk.py tests/codex_bridge/test_sdk_stream_cleanup.py -q`. Expected: fail.
- [ ] **Step 3: Implement.** Factor client creation from `run` into `_ensure_client()` used by
  both methods: it builds `AsyncCodex(...)` once and awaits its public `__aenter__()`, which
  runs the SDK's start and initialize now (in 0.163.0 `models()` would otherwise initialize
  lazily, and an initialize error is a broken client, not a catalog answer). Errors from
  `_ensure_client()` take the same mapping `run` uses (`SDK_FAILURE`). `check` catches
  `JsonRpcError` only around the `models(include_hidden=True)` call itself and maps it to
  `CATALOG_UNAVAILABLE`; everything else propagates through that same mapping. `run` passes
  `model=selection.model` to `thread_start` and `model=selection.model,
  effort=ReasoningEffort(selection.effort)` to `thread.turn`. A reroute's `to_model` is kept
  only when it matches `MODEL_RE` and its reason only when it matches `[A-Za-z0-9_.-]{1,64}`
  (else `None`). The pre-return size check calls `mcp_result(reply_payload(...))`.
- [ ] **Step 4: Run** the SDK tests, then the whole `tests/codex_bridge` folder. Expected: pass
  except the pre-existing live-driver failure.
- [ ] **Step 5: Commit** `feat: pass the selected model and effort to every Codex turn`.

### Task 5: Adapter CLI flags and launcher hand-off

**Files:**
- Modify: `gauntlet_review/codex_bridge/server.py` (`main`), `gauntlet_review/launch.py`
  (`server_argv`, `main`, module docstring)
- Test: `tests/codex_bridge/test_server.py`, `tests/collaborative/test_launch.py`

**Interfaces:**
- Consumes: Task 3 (`BridgeConfig` fields).
- Produces: adapter flags `--effort EFFORT` and `--model-settings-root DIR`;
  `server_argv(role, launch, timeout_seconds, extended_timeout=False, state_root=None)`, whose
  peer argv is `[*common, "--model-settings-root", str(state_root), "--participant",
  "claude-peer", "--timeout-seconds", N, (EXTENDED_TIMEOUT_FLAG)]`.

- [ ] **Step 1: Write the failing tests.**
  - `test_server.py`: the `Peer` fake gains `check` and `run(prompt, selection)`; the status key
    set includes `peer_model`. `test_cli_model_flags_build_the_config` (monkeypatch
    `create_server` to capture the config): `--model m --effort high` gives fixed mode;
    `--model-settings-root <abs>` gives settings mode; `--model-settings-root` with `--model`
    or `--effort`, and a relative root, exit 2 with stderr `{"code":"CONFIGURATION_ERROR",
    "cause":"model_mode"}` and never call `create_server`.
  - `test_launch.py`: the exact peer argv in `test_main_hands_the_derived_tuple_to_the_server`
    gains `"--model-settings-root", str(root)` after the common arguments; the core argv is
    unchanged.
- [ ] **Step 2: Run** both files. Expected: fail.
- [ ] **Step 3: Implement** the flags (validate mutual exclusion and absoluteness in `main`
  before building the config) and the hand-off argument; `launch.main` passes `state_root`.
  Update the launcher docstring's usage lines.
- [ ] **Step 4: Run** both files. Expected: pass.
- [ ] **Step 5: Commit** `feat: give the launcher's peer the operator's model settings`.

### Task 6: Operator commands (`gauntlet_review/model_cli.py`)

**Files:**
- Create: `gauntlet_review/model_cli.py`
- Modify: `gauntlet_review/launch.py` (`main` dispatch only)
- Test: `tests/collaborative/test_model_cli.py` (copies the small `checkout` fixture and
  `git` helper from `test_launch.py` rather than moving them, because the session-server fix
  also edits that file)

**Interfaces:**
- Consumes: Task 1 (whole module), Task 2 (`fetch_catalog`, `find`, `check`, `Catalog`),
  `codex_bridge.server._require_extra`, `launch._repository_id`, `launch._log`, `launch._slug`.
- Produces: `main(argv: list[str]) -> int`; `repository_id_of(folder: Path) -> str`;
  module attribute `fetch_catalog` (tests replace it). `launch.main(argv)` returns
  `model_cli.main(argv)` when `argv[0]` is `models` or `model` (argv `None` means
  `sys.argv[1:]`), before building its own parser.
- JSON shapes (`--json`): `models` prints `{"selection": <public selection>, "models":
  [{"model","display_name","catalog_default","hidden","default_effort","efforts"}]}`; `model`
  show prints `{"scope": "global", "selection", "repositories": {id: {"settings": {...},
  "selection": {...}}}}` or `{"scope": "repository", "repository_id", "settings",
  "selection"}`; a change prints `{"scope", "repository_id", "settings", "selection",
  "warnings": [{"repository_id","model","effort","code"}]}`. Human output is the builder's.

- [ ] **Step 1: Write the failing tests** (fake catalog: the three models from Task 2; a
  `fetch_catalog` stub that counts calls or raises):
  - `test_models_lists_visible_models_and_the_selection`, `--all` adds the hidden one,
    `--json` matches the shape; a pin failure gives `MISSING_EXTRA`.
  - `test_show_on_a_fresh_install_creates_nothing` (Review Focus 5): `models` and `model` on
    a missing root report the built-in default and the root does not exist afterwards.
  - `test_set_model_only_effort_only_and_both`: each writes only the named fields (read the
    file back), logs one `peer-model set scope=... ` line, and prints the new selection.
  - `test_display_names_and_capitals_are_accepted` (Review Focus 3): `GPT-6-LUNA` stores
    `gpt-6-luna`; `--effort HIGH` stores `high`.
  - `test_unknown_model_and_unsupported_effort_write_nothing`: `gpt-7` gives `UNKNOWN_MODEL`;
    `gpt-6-luna --effort ultra` gives `EFFORT_NOT_SUPPORTED` naming luna's efforts; with
    global effort `ultra`, `gpt-6-luna` for a repository is refused for the inherited effort.
    The file is byte-identical afterwards.
  - `test_a_global_change_warns_about_broken_repositories`: repository `r` sets effort `ultra`;
    global `gpt-6-luna --effort high` is written, exits 0 and warns about `r`.
  - `test_catalog_unavailable_writes_nothing`: the stub raises; `CATALOG_UNAVAILABLE`.
  - `test_reset_needs_no_catalog`: `--reset effort`, `--reset model` and `--reset` remove
    those fields, drop empty entries, never call the stub, and log `peer-model reset`.
  - `test_repo_derives_the_launchers_id` (Review Focus 4): `--repo <checkout>`,
    `--repo <checkout>/sub` and `--repo <linked worktree>` all store `owner-repo`; a folder
    outside any checkout gives `NOT_A_GIT_CHECKOUT`.
  - `test_repository_ids_must_be_slugs` (Review Focus 2): `--repository-id Owner-Repo` and
    `owner_repo` give `CONFIGURATION_ERROR`; `owner-repo` is accepted.
  - `test_argument_refusals` (parametrized): `--repo` with `--repository-id`; `--reset` with a
    model or `--effort`; a relative `--state-root`; model `"bad model"`. Each is
    `CONFIGURATION_ERROR` and writes nothing.
  - `test_invalid_settings_are_reported`: an invalid file gives `MODEL_SETTINGS_INVALID` for
    show and for a change.
  - `test_a_change_beyond_the_limits_writes_nothing`: with 256 repositories, a 257th; and a
    near-limit file plus an ordinary model change whose written form crosses 64 KiB. Each gives
    `CONFIGURATION_ERROR` naming the limit, leaves the file byte-identical and logs nothing.
  - `test_a_failed_save_reports_and_logs_nothing`: `peer_model.save` raises `OSError`; the
    command gives `STATE_UNAVAILABLE`, exit 2, and `launch.log` gains no `peer-model` line.
  - `test_launch_dispatches_the_subcommands`: `launch.main(["models", ...])` reaches
    `model_cli.main`; `launch.main(["check"])` still runs the pin check.
- [ ] **Step 2: Run** `& $py -m pytest tests/collaborative/test_model_cli.py -q`. Expected: fail.
- [ ] **Step 3: Implement `model_cli.py`.** One argparse parser per subcommand (`exit_on_error`
  off, errors become `CONFIGURATION_ERROR`). `repository_id_of`: dulwich `Repo.discover`,
  origin URL and `Path(repo.commondir()).resolve().parent`, then `launch._repository_id`, as
  `launch.derive` does, without its branch and target checks. `--repository-id` must satisfy
  `launch._slug(value) == value` and `REPOSITORY_RE`. Before a change, compute the new settings
  with `with_fields`, resolve the scope's pair, and check it with the catalog (mapping
  `MODEL_UNAVAILABLE` to `UNKNOWN_MODEL`); for a global change, check every repository's new
  effective pair and report failures as warnings. Catalog exceptions of any kind become
  `CATALOG_UNAVAILABLE` with the hint "check that Codex is installed and signed in". Save,
  then log: a `SettingsError` from `save` is reported with its code, an `OSError` as
  `STATE_UNAVAILABLE`, and the log line is written only after `save` returns.
- [ ] **Step 4: Run** the new tests and `tests/collaborative/test_launch.py`. Expected: pass.
- [ ] **Step 5: Commit** `feat: add launcher commands to list and switch the peer model`.

### Task 7: `/gauntlet-model` skill and installer

**Files:**
- Create: `gauntlet-model/SKILL.md` and `gauntlet-model/registration.ps1` (repository root)
- Modify: `install.ps1` (the skill copy loop: `'gauntlet-review','gauntlet-dev','gauntlet-model'`)
- Test: `tests/test_skill_files.py` (Python, under `gauntlet-review/python/tests`) and
  `tests/test-gauntlet-model-registration.ps1` (repository root, run with `pwsh`)

**Interfaces:**
- Consumes: Task 6's command lines and JSON output.
- Produces: `registration.ps1 [-HomeDir <dir>]`, which prints one JSON line
  `{"python": "<command>", "state_root": "<value after --state-root>"}` for the active
  profile's `gauntlet-peer` entry and exits 0, or prints one line naming the profile file it
  read and exits 1. The active profile follows the installer's rule
  (`Get-GauntletClaudeProfile` in `mcp-registration.ps1`): `$env:CLAUDE_CONFIG_DIR/.claude.json`
  when that is set, else `<HomeDir>/.claude.json` (`-HomeDir` defaults to `$HOME`). It never
  falls back to the other profile.

- [ ] **Step 1: Write the failing test** `test_gauntlet_model_skill_is_user_only_and_installed`:
  the skill's frontmatter (parsed between the first two `---` lines) has `name:
  gauntlet-model`, `disable-model-invocation: true` and no `allowed-tools` key; its body
  contains `gauntlet_review.launch models` and `gauntlet_review.launch model` and no em-dash character (U+2014, `chr(0x2014)`);
  `install.ps1`'s skill loop names `gauntlet-model`.
  And `tests/test-gauntlet-model-registration.ps1` (fixtures: a home folder and a custom
  profile folder whose `.claude.json` files register different `command` and `--state-root`
  values): with `CLAUDE_CONFIG_DIR` set, the custom profile's values are printed; with it
  unset, the home folder's; with `CLAUDE_CONFIG_DIR` set to a profile lacking the entry while
  the home profile has one, exit 1 naming the custom profile file (no fallback); an
  unparseable profile exits 1. The test restores `CLAUDE_CONFIG_DIR` in `finally`.
- [ ] **Step 2: Run** `& $py -m pytest tests/test_skill_files.py -q` and
  `pwsh tests/test-gauntlet-model-registration.ps1`. Expected: fail.
- [ ] **Step 3: Write the skill.** Frontmatter: `name`, a `description` ("Show, list or switch
  the Codex model and reasoning effort Gauntlet's peer reviewer uses"),
  `disable-model-invocation: true`, `argument-hint: [model] [effort] [for this repository] |
  effort <e> | reset [model|effort]`. `registration.ps1` reads the active profile with
  `ConvertFrom-Json -AsHashtable`. Body: run `& "$skillDir/registration.ps1"` (the skill's own
  folder) and stop, relaying its message and "Gauntlet is not registered in this profile; run
  install.ps1", when it exits 1. Run `& $py -I -m gauntlet_review.launch …` with `--json` and summarize. Map the
  argument forms in the spec; "this repository" is `--repo (Get-Location)`. With no
  arguments run `model --json`, `model --repo . --json` and `models --json`. Say a change
  applies from the next peer turn, and relay warnings.
- [ ] **Step 4: Edit `install.ps1`** and run the test. Expected: pass.
- [ ] **Step 5: Commit** `feat: add the /gauntlet-model skill`.

### Task 8: Documentation

**Files:**
- Modify: `docs/collaborative-mcp.md`, `gauntlet-review/SKILL.md`,
  `gauntlet-review/references/collaborative-review.md`, `README.md`
- Create: `docs/build-log/2026-11-22-peer-model-selection.md`

- [ ] **Step 1: `docs/collaborative-mcp.md`.** Replace "It uses the native host's configured
  model unless the operator supplies `--model`" with the built-in default and the fixed and
  settings modes. Add a "Peer model and effort" section: the settings file and per-field
  inheritance, the two subcommands with examples, the per-turn catalog check and its three
  certain codes plus `MODEL_SETTINGS_INVALID`, `peer_model` in status and replies (with
  `rerouted`), the `/gauntlet-model` skill, and who can change the setting. Mention the
  `--model-settings-root` hand-off in Global registration.
- [ ] **Step 2: `gauntlet-review/SKILL.md`** (Essential checks 1) and the reference
  (Preflight): read `peer_model` from `codex_status`, report the model and effort with each
  gate's result, treat the four new codes as certain refusals (no fresh conversation needed;
  tell the user what to fix), and never change the setting; the user runs `/gauntlet-model`.
- [ ] **Step 3: `README.md`:** the prerequisites line names the default and how to switch.
- [ ] **Step 4: Build log:** why (the native-config finding), design, tests, live checks.
- [ ] **Step 5: Check** `Select-String -Path <each file> -Pattern ([char]0x2014)` (the em-dash) finds nothing, then
  commit `docs: describe the peer model and effort settings`.

### Task 9: Verification

- [ ] **Step 1:** Full suite: `& $py -m pytest tests -q -p no:cacheprovider` from
  `gauntlet-review/python`. Expected: every test passes except failures also present on the
  pre-change baseline (record the baseline list from `main` in the build log).
- [ ] **Step 2:** `pwsh tests/run-tests.ps1`, `pwsh tests/test-install-registration.ps1` and
  `pwsh tests/test-gauntlet-model-registration.ps1`
  from the repository root. Expected: same results as on the baseline.
- [ ] **Step 3: Live catalog check** (no model turn): with a scratch state root,
  `& $py -I -m gauntlet_review.launch models --state-root <scratch>` lists the real catalog;
  `model gpt-6-sol --effort high`, `model`, `model --reset` behave as specified; the real
  `~/.local/share/gauntlet/state` is untouched.
- [ ] **Step 4: Live turn check** (one short model turn, operator's own Codex account): run
  the explicit-tuple adapter from this worktree through an in-memory MCP client against a
  scratch clone and scratch state, with `--model-settings-root <scratch>` set to
  `gpt-6-sol`/`high`; send the prompt "Reply with the single word ready."; the reply's
  `peer_model` is `gpt-6-sol`/`high`. Then set an effort the model lacks by editing the file
  and confirm `EFFORT_NOT_SUPPORTED` with no turn and state `ready`.
- [ ] **Step 5:** Record results in the build log and commit.

### Task 10: Integrate with the session-server fix

Run when `claude/gauntlet-mcp-reconnect-8ea905` (or `main` after it merges) has its code.

- [ ] **Step 1:** Rebase this branch onto it. Resolve `launch.py` by keeping the session-server
  version: drop the `--model-settings-root` hand-off argument and its `test_launch.py`
  assertion along with `server_argv`; keep the `models|model` dispatch at the top of `main`.
- [ ] **Step 2:** In `session.py`, build each peer binding's `BridgeConfig` with
  `model_settings_root=<the resolver's state root>` and no `model`.
- [ ] **Step 3:** In `tests/codex_bridge/test_session_peer.py`, give the fake conversation
  `check(selection)` and `run(prompt, selection)` and allow `peer_model` in status and reply
  key sets. Add `test_each_binding_uses_its_repositorys_override`: two checkouts with
  different origin owners, an override for one; each binding's status reports its own
  selection.
- [ ] **Step 4:** Update the docs' Global registration text to the session-server wording.
- [ ] **Step 5:** Re-run Task 9 Steps 1 and 2, then commit `fix: carry the peer model settings
  into session servers`.
