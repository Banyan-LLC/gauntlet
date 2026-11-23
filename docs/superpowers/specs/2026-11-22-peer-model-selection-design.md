# Operator-selected peer model and reasoning effort

Date: 2026-11-22. Status: draft for the user's spec gate (the user skipped the spec peer
review; the plan gate and the branch review run).

## Why

The operator wants to choose which Codex model reviews their work, and how hard it reasons,
without editing code or registrations: "gauntlet can continue to default to gpt-6.1-sol, but
users should have a command to list available models, and switch the model and effort."

Today the collaborative peer has no model or effort setting of its own:

- The SDK adapter (`gauntlet_review/codex_bridge`) passes `model=None` to `thread_start`
  unless an explicit-tuple registration supplies `--model`. The global launcher
  (`python -m gauntlet_review.launch peer`) has no model flag at all.
- With `model=None` the Codex runtime uses the operator's native `~/.codex/config.toml`.
  On this machine that file says `model = "gpt-6.1-sol"` and
  `model_reasoning_effort = "xhigh"`, which is the only reason reviews run on gpt-6.1-sol
  at xhigh. The Codex catalog's own default (as of 2026-11-22, SDK and runtime 0.163.0) is
  `gpt-6.1-terra`, and gpt-6.1-sol's catalog default effort is `low`. On a machine without
  those two native lines, a Gauntlet review silently runs a different model at a lower
  effort.
- There is no effort setting anywhere in the adapter.

`docs/design.md` already names gpt-6.1-sol at xhigh as Gauntlet's reviewer setting (the
legacy runner pins it with `-m` and `-c model_reasoning_effort`). This work makes the
collaborative peer state that default explicitly and lets the operator change it.

## Goals

- Gauntlet's peer defaults to `gpt-6.1-sol` at `xhigh`, stated in Gauntlet's code, not
  inherited from the native configuration.
- The operator can list the models Codex offers (with each model's supported efforts) and
  switch the model, the effort, or both, globally or for one repository.
- The choice persists across sessions and takes effect on the **next peer turn**, with no
  reconnect, restart or reinstall.
- `codex_status` reports the model and effort the next turn will use, and every completed
  `codex_review` reply names the model and effort that turn used, so agents and the operator
  can see what reviewed the work.
- Unknown models and efforts are refused when the operator sets them, and checked against
  Codex's catalog again before every turn, so a model Codex stops offering is refused cleanly
  instead of breaking the conversation.

## Non-goals

- Any change to the review core (contract, store, policy, limits), to the reviewer core the
  adapter registers for each Codex thread, or to the legacy runner and its pinned premises.
- Recording the model in the core's review store or verdicts. The reply and status carry it;
  an author may record it as evidence.
- Choosing models per branch or per checkout. Overrides are per repository.
- Service tier, personality or other model options.

## Anti-goals

- The Codex reviewer must never be able to change its own model or effort. No MCP tool
  changes the setting, and nothing the reviewer can reach writes it.
- An author agent must not quietly change the reviewer (for example to a weaker model) on
  its own initiative. The author host gets read-only visibility; changes come from the
  operator.
- A broken or unreadable setting must never silently fall back to some other model. It is
  refused before any turn starts.

## Decisions the user made

1. **Command:** launcher subcommands, plus a user-invocable `/gauntlet-model` skill that runs
   them. (Rejected: MCP tools on `gauntlet-peer`, because the session-server design fixes
   models for the author host and an author agent could weaken its own reviewer.)
2. **Storage:** a global default in the operator's state root plus optional per-repository
   overrides.
3. **When a switch applies:** the next peer turn, even inside an open conversation. (Rejected:
   next conversation only, because a peer conversation lives for the whole host session, so a
   switch would wait for a new session.)
4. **Per-field overrides:** "users can override the model, the effort, or both at any time
   between turns." A scope (global or one repository) may set only the model, only the
   effort, or both; an unset field follows the next scope up.
5. **Per-turn catalog check:** before every turn the adapter checks the selected model and
   effort against Codex's catalog, so a model Codex no longer offers is refused cleanly
   (no poisoned conversation) and a switch fixes it on the next call.
6. **Process:** no spec peer review; plan gate and branch review run.

My call (the user can override it at this gate): `/gauntlet-model` is a slash command only the
user can run (`disable-model-invocation: true`), and it pre-approves no commands, so the host
still asks before each one runs.

## Approaches considered for the mechanism

- **Per-turn read of a settings file (chosen).** The adapter reads the operator's settings at
  the start of each `codex_review` turn and passes `model` and `effort` to the SDK turn. The
  SDK supports both per turn (`AsyncThread.turn(..., model=, effort=)`, documented as "this
  turn and subsequent turns"). A switch applies on the next turn with no restart; each reply
  states what it used.
- **Launcher flags in the registration** (`--model`, `--effort` on the user-scope entry).
  Persistent, but a switch means re-registering and reconnecting every session, and there is
  no per-repository override. Rejected.
- **Settings read once when a conversation starts.** One model per conversation, but the
  switch waits for a new host session (see decision 3). Rejected.

## Design

### Built-in default

A new stdlib-only module, `gauntlet_review/peer_model.py`, owns the constants
`DEFAULT_MODEL = "gpt-6.1-sol"` and `DEFAULT_EFFORT = "xhigh"`. Every adapter path that has
no other setting uses them, and always passes both to the SDK explicitly, so the native
`config.toml` no longer decides the reviewer's model or effort.

### The settings file

`<state-root>/peer-model.json`, beside `launch.log`, so it covers every checkout the launcher
serves and sits outside every repository (the launcher already refuses a state root inside a
checkout). Version 1:

```json
{
  "version": 1,
  "default": {"effort": "max"},
  "repositories": {
    "banyan-llc-gauntlet": {"model": "gpt-6-sol"},
    "banyan-llc-ajend-app": {"model": "gpt-6-astra", "effort": "high"}
  }
}
```

- `default` and `repositories` are optional; a missing file means no settings.
- Repository keys are the launcher's repository IDs (`<owner>-<repository>` from origin's
  URL, else the main checkout's folder name; the same `[A-Za-z0-9_-]{1,64}` rule). An
  override applies to every checkout and branch of that repository.
- Each entry (`default` or a repository's) holds `model`, `effort` or both, and at least one
  of them; the writer drops an entry that becomes empty. Models match the adapter's existing
  model rule (`[A-Za-z0-9_./:-]{1,128}`); efforts match `[a-z]{1,32}`.
- Bounds: at most 64 KiB and 256 repository entries. Unknown keys, a wrong version, a
  duplicate key, an empty entry, invalid JSON or a value outside these rules make the file
  invalid.

Reading applies the launcher's no-follow rule: the state root must pass
`check_unredirected`, and the file itself must be a regular file, not a symbolic link,
junction or other reparse point. A missing state root or missing file means no settings.
Any other problem is `MODEL_SETTINGS_INVALID`; there is no fallback.

Writing (only the CLI writes) creates the state root as a private directory if it is
missing (the launcher's `ensure_private_dir`), writes a temporary file in the state root and
replaces `peer-model.json` atomically. Concurrent writers are not coordinated; the last
replace wins, which is acceptable for an operator command. Each change appends one line to
`launch.log`, for example `peer-model set scope=repository:banyan-llc-gauntlet
model=gpt-6-sol` or `peer-model reset scope=global fields=effort`.

### Resolution for a turn

For a bridge whose operator tuple has repository ID `R`, each field resolves on its own:

- model: `repositories[R].model`, else `default.model`, else `DEFAULT_MODEL`;
- effort: `repositories[R].effort`, else `default.effort`, else `DEFAULT_EFFORT`.

Each field's source is `repository`, `global` or `built_in`. The result is a
`Selection(model, effort, model_source, effort_source)`.

### Adapter (engine, SDK, explicit-tuple CLI)

`BridgeConfig` gains `effort: str | None = None` and `model_settings_root: Path | None = None`
next to the existing `model`. Exactly one of two modes applies:

- **Fixed:** `model_settings_root` is `None`. The selection is `model or DEFAULT_MODEL` and
  `effort or DEFAULT_EFFORT`; each field's source is `operator` when it was given, else
  `built_in`.
- **Settings:** `model_settings_root` is an absolute path and `model` and `effort` are both
  `None` (giving either is `CONFIGURATION_ERROR`). The selection is resolved from the file for
  the bridge's repository ID, fresh for every turn and every status call.

`validate_config` checks the effort rule and the mode rule as it checks the model today.

`Bridge.status()` always adds `peer_model`: `{"model", "model_source", "effort",
"effort_source"}` for the selection the next turn would use, or
`{"error": "MODEL_SETTINGS_INVALID"}` when the file is invalid (status itself still succeeds
and starts nothing). This is a deliberate change to the default status shape.

`Bridge.call()` then works in this order:

1. The existing admission checks (exact replay, busy, poisoned, thread mismatch, cache bound).
   An exact replay returns the original reply, including the model it used then, even after a
   switch.
2. Resolve the selection. An invalid file returns `MODEL_SETTINGS_INVALID` (cause
   `model_settings`).
3. Mark busy and, inside the turn deadline, run the **catalog check**:
   `conversation.check(selection)` asks Codex for its catalog (`model/list` with hidden models
   included, on the conversation's own SDK client, which starts on first use as today; no
   model turn). The model must be listed and the effort must be among that model's supported
   efforts. Refusals: `MODEL_UNAVAILABLE`, `EFFORT_NOT_SUPPORTED`, and `CATALOG_UNAVAILABLE`
   when Codex answers the catalog request with an error, or the answer carries a next-page
   cursor and the model is not on the page returned (the SDK in 0.163.0 cannot request further
   pages; today's catalog fits in one).
4. `conversation.run(prompt, selection)` runs the turn exactly as today.

The refusals in steps 2 and 3 are certain: no turn was started. They return `uncertain:
false`, leave the conversation unpoisoned, close nothing and are not cached under the key, so
the next call after the operator switches or fixes the file proceeds in the same
conversation. Any other failure during the check (transport closed, deadline, an unexpected
error) takes today's failure path (uncertain, poisoned, cleanup), because the SDK client can
no longer be trusted. A model the catalog lists but Codex refuses when the turn starts (for
example one the account cannot use) still fails as today (`SDK_FAILURE`, poisoned); the check
cannot see that.

A completed reply becomes `{"ok", "thread_id", "turn_id", "text", "peer_model"}`, where
`peer_model` has the status shape for the selection that turn used, plus
`"rerouted": {"to", "reason"}` when the runtime rerouted the turn to another model (below).
Error replies are unchanged apart from the new codes.

`SdkConversation.run(prompt, selection)` passes `model=selection.model` to `thread_start`
(the thread's default) and `model=selection.model, effort=selection.effort` to every
`thread.turn`. While streaming, a `model/rerouted` notification for the same thread and turn
(the SDK routes it to the turn's stream) records `to_model` and `reason`, reported as
`rerouted`. The size checks the SDK layer runs before returning a reply use the same payload
shape the engine builds.

The explicit-tuple adapter CLI (`python -m gauntlet_review.codex_bridge`) keeps `--model`
and gains `--effort` and `--model-settings-root DIR`. With neither model flag it uses the
built-in default (previously it inherited the native configuration; this is a deliberate,
documented change). `--model-settings-root` together with `--model` or `--effort` is refused
at startup.

### Launcher wiring

The launcher's peer gets the settings mode with the state root as `model_settings_root`.
On today's `main` that is one more hand-off argument (`--model-settings-root <state-root>`);
after the session-server fix it is the `BridgeConfig` the peer session server builds for each
binding (see Compatibility). The launcher gains no model flags.

### Operator commands

Two new launcher subcommands, dispatched before the existing `core|peer|check` parsing so
that parser is untouched. `SCOPE` is `--repo PATH` or `--repository-id ID` (one repository);
without it the scope is global. `--repo` derives the repository ID from that folder exactly as
the launcher does, whatever the branch state.

```
python -I -m gauntlet_review.launch models --state-root <root> [--all] [--json]
python -I -m gauntlet_review.launch model  --state-root <root> [SCOPE] [--json]
python -I -m gauntlet_review.launch model  --state-root <root> [MODEL] [--effort EFFORT] [SCOPE]
python -I -m gauntlet_review.launch model  --state-root <root> --reset [model|effort|all] [SCOPE]
```

- `models` asks Codex for its catalog through the SDK (a `model/list` request that starts no
  model turn) and prints each model's name, display name, supported efforts and catalog
  default effort, marking the catalog's default model and the current global selection.
  `--all` includes models Codex hides from its picker. It needs the same pinned `[codex]`
  extras as the adapter.
- `model` with no change shows the effective selection with each field's source: globally
  (plus every repository entry and its effective pair), or for the one repository in `SCOPE`.
- `model MODEL`, `model --effort EFFORT` or both set exactly the named fields in the scope's
  entry and nothing else, so setting a model never pins an effort and the reverse. The scope's
  resulting effective pair (after inheritance) must be in the full catalog (hidden models
  included) with that effort supported; otherwise the change is refused with
  `UNKNOWN_MODEL` or `EFFORT_NOT_SUPPORTED` (which lists the model's efforts) and nothing is
  written. A global change also reports, as warnings, every repository whose own effective
  pair would no longer be supported; the change is still written, and those repositories'
  turns are refused cleanly by the per-turn check until the operator fixes them.
- `model --reset [model|effort|all]` (default `all`) removes those fields from the scope's
  entry, so they follow the next scope up again. It does not contact Codex, so it works when
  the catalog cannot be reached.
- Output is human-readable; `--json` prints one JSON document instead. Refusals print one line
  `CODE: message` on stderr and exit 2. Codes: `CONFIGURATION_ERROR` (arguments, state
  root), `UNKNOWN_MODEL`, `EFFORT_NOT_SUPPORTED`, `CATALOG_UNAVAILABLE` (Codex could not be
  reached or is not signed in), `MODEL_SETTINGS_INVALID`, `NOT_A_GIT_CHECKOUT` (for `--repo`),
  `MISSING_EXTRA` and `UNSUPPORTED_EXTRA`, and the launcher's state-root codes. A refused
  change writes nothing.

These are operator commands run in a terminal or by the `/gauntlet-model` skill. They run
outside any MCP server, so a change takes effect at the next turn of every running peer.

### The `/gauntlet-model` skill

A new skill folder, `gauntlet-model/` (installed by `install.ps1` beside `gauntlet-review`
and `gauntlet-dev`). Its frontmatter sets `disable-model-invocation: true`, so only the user
can run it, by typing `/gauntlet-model`, and it lists no `allowed-tools`, so the host still asks
before each command runs. It:

- finds the venv Python and `--state-root` from the user-scope `gauntlet-peer` entry in
  `~/.claude.json` (`mcpServers.gauntlet-peer`), and reports a missing registration instead
  of guessing paths;
- with no arguments, shows the current selection (global and this repository) and the model
  list; maps requests such as `/gauntlet-model gpt-6-sol high`, `/gauntlet-model effort max`,
  `/gauntlet-model gpt-6-sol for this repository` and `/gauntlet-model reset effort` onto the
  subcommands, using `--repo` with the current working folder for "this repository";
- reports the command's result, including any warnings, and notes that the change applies from
  the next peer turn.

### Who can change the setting

- The operator, through the subcommands or the user-only `/gauntlet-model` skill.
- Not the Codex reviewer: its thread runs read-only with every approval denied and only the
  four reviewer core tools; the settings file is in the state root, outside every repository,
  and nothing those tools do writes it.
- Not through MCP: `codex_status` and `codex_review` only report the selection. An author
  agent could run the subcommand through its shell under the host's own permission prompts,
  as it could edit any of the operator's files; the `gauntlet-review` skill tells agents to
  leave the setting to the user and to point them at `/gauntlet-model`.

## Compatibility and rollout

- **Session-server fix** (`claude/gauntlet-mcp-reconnect-8ea905`, spec
  `2026-11-22-session-follows-checkout-design.md`): this work ships after it and is rebased
  onto it. That fix replaces the launcher hand-off with per-binding bridges built by
  `create_peer_server(resolver, timeout_seconds, extended_timeout, model=None)`. On rebase:
  the hand-off argument is dropped with the hand-off, the peer session server builds each
  binding's `BridgeConfig` with `model_settings_root=<state root>` (and no `model`), and that
  server's tests and fake conversations adopt `check(selection)`, `run(prompt, selection)`
  and the `peer_model` status and reply field. Each binding resolves with its own repository ID, so a
  per-repository override follows the checkout an agent names. The session fix's trust
  boundary ("models ... remain fixed" for the author host) holds: the author host still
  cannot select a model.
- Existing stores and review history are untouched. A missing settings file keeps this
  machine's current behavior (gpt-6.1-sol at xhigh). A machine whose native configuration
  chose another model now gets gpt-6.1-sol at xhigh until the operator switches.
- `codex_status` and completed `codex_review` replies gain `peer_model`; clients that check
  exact key sets must allow it.
- Rollout: update the installed source checkout and run `install.ps1` (which also installs the
  skill). Sessions started before that keep their old servers until their next start.

## Testing

- Settings: missing root or file gives the built-in default; per-field inheritance (a
  repository that sets only the effort follows the global model, and the reverse) with each
  field's source; every invalid shape (bad JSON, version, unknown or duplicate keys, an empty
  entry, bad model, effort or repository ID, too many entries, oversize file, a symbolic link
  or junction in place of the file or a redirected root) gives `MODEL_SETTINGS_INVALID`;
  writes are atomic and private and leave no temporary files; a reset removes only its fields
  in its scope and drops an entry that becomes empty.
- Commands, with a fake catalog: `models` output, `--all` and `--json`; show globally and for
  one repository; set model only, effort only and both, each writing only the named fields;
  `UNKNOWN_MODEL` and `EFFORT_NOT_SUPPORTED` for the scope's resulting pair, including an
  inherited effort the new model lacks; a global change warns about repositories it breaks
  and still writes; `CATALOG_UNAVAILABLE`; reset works with no catalog; `--repo` derives the
  launcher's repository ID from a Git fixture; `--repo` and `--repository-id` together are
  refused; refusals write nothing; each change logs one line; `launch.main` dispatches both
  subcommands and leaves `core|peer|check` unchanged.
- Engine: `peer_model` in status for fixed, built-in and settings modes and for an invalid
  file; a switch between two turns changes the second turn's model and effort and the
  replies say so; an invalid file and each catalog-check refusal (`MODEL_UNAVAILABLE`,
  `EFFORT_NOT_SUPPORTED`, `CATALOG_UNAVAILABLE`) refuse with no turn, `uncertain: false`, no
  poisoning and no cache entry, and the next call after a fix succeeds in the same
  conversation; a check that raises anything else poisons as today; replay after a switch
  returns the original `peer_model`; configuration refusals for a bad effort and for
  settings mode with a fixed model or effort.
- SDK: the check asks for the catalog with hidden models and answers each case, including a
  paged answer; `thread_start` receives the model; every turn receives model and effort; a
  matching `model/rerouted` notification appears as `rerouted`, a foreign one does not.
- Adapter CLI and launcher: `--effort` and `--model-settings-root` parsing and the mutual
  exclusion; the launcher hands the state root to the peer only.
- Installer: the skill folder is copied with the other two; its frontmatter disables model
  invocation and lists no allowed tools.
- Docs: `docs/collaborative-mcp.md`, the `gauntlet-review` skill and reference, and the
  README describe the default, the commands, the skill and the new fields, with no
  em-dashes.

## Left to the builder

- Exact human-readable output layout of `models` and `model`, and the JSON field names
  beyond those named here.
- How the skill reads `~/.claude.json` (a short PowerShell snippet is expected).
- Internal function names and module layout beyond `peer_model.py` and the `BridgeConfig`
  fields.
