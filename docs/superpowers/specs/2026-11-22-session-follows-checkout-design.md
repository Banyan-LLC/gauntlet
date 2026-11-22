# Session servers that follow the checkout

Date: 2026-11-22. Status: draft for the plan gate (the user skipped the spec peer review).

## Problem

Agents keep reporting that Gauntlet is "paired with another branch or worktree" and ask
the operator to reconnect the MCP servers, nearly every time a review is attempted. The
launcher log (`<state-root>/launch.log`) and the Claude Code configuration show three causes:

1. **The branch is frozen at startup.** The launcher reads the session folder's checked-out
   branch once, when the host starts the server, and hands that tuple to a server that can
   never change it. Desktop worktree sessions start on `claude/<worktree>`; agents then create
   `feat/...`, and the server stays bound to the old branch until the operator reconnects. One
   worktree went through five branches, each needing a reconnect; another was launched 58 times.
2. **The checkout is frozen at startup.** A session that works in a different worktree than
   its start folder keeps reviewing the start folder. A session started outside a checkout or
   on a detached HEAD gets no Gauntlet tools at all: the log holds 201 `NOT_A_GIT_CHECKOUT` and
   135 `DETACHED_HEAD` refusals, each a dead server for the whole session.
3. **Shadowing per-project registrations.** Explicit-tuple `gauntlet-core`/`gauntlet-peer`
   entries under `projects.<path>.mcpServers` in `~/.claude.json` take precedence over the
   user-scope launcher entry. Claude Code resolves a linked worktree's local scope to its main
   repository's entry, so every worktree session of this repository ran a server pinned to
   `main` of the main checkout. (Operational fix done 2026-11-22: the three projects' entries
   were backed up to a private file and removed.)

## Goals

- A session never needs a reconnect because its branch changed, because it works in another
  checkout, or because it started outside a usable checkout.
- Every response says which checkout and refs it used, so agents can verify the binding
  before trusting a result.
- The installer finds and removes shadowing per-project registrations.
- Existing review stores keep working: the derivation and the store directory names are
  unchanged, so a binding reaches the same store a launcher process did before.

## Non-goals

- Reviewing a detached HEAD. It is still refused, but per call, with a hint, and the server
  stays up so the next call succeeds once a branch is checked out.
- Any change to the review core's contract, policy, store format or limits, to the
  explicit-tuple entry points (`gauntlet_review.collaborative`, `gauntlet_review.codex_bridge`),
  or to the reviewer core the adapter registers for each Codex thread.
- Remote freshness, fetching, or `.mcp.json` files checked into repositories.

## Design

### Session servers

`python -m gauntlet_review.launch core|peer --state-root <dir>` no longer derives a tuple and
hands off to a fixed-tuple server. It starts a **session server** that keeps two fixed
values: the session folder (its working folder at startup) and the state root. Startup
refuses only what no call could fix: a bad or redirected state root, missing or unsupported
pins, and an out-of-range peer timeout (same codes and stderr rules as today). It never
refuses because of the session folder's Git state.

### Binding per call

Every tool accepts one new optional top-level argument, `checkout`: the absolute path of the
checkout (or any folder inside it) the agent is working in. Absent or `null` means the session
folder. On **every** call the server derives the binding from that folder with the existing
`launch.derive` (fresh HEAD and origin reads, same repository ID, same state directory name)
and makes its private state directory with the existing `ensure_private_dir`. A branch switch
or a new worktree therefore takes effect on the next call with no restart.

`checkout` must be a string of at most 4096 UTF-8 bytes, absolute, with no control
characters and no UNC (`\\`, `//`) prefix; anything else is `INVALID_ARGUMENT` before any
filesystem access.

Each response carries `binding`: `{"checkout", "repository_id", "source_ref", "target_ref"}`
(the resolved checkout path and full ref names), or `null` when no binding could be derived.
The state directory is never shown or selectable.

A derivation failure is an ordinary tool error, never a dead server. Its code is the
launcher's code (`NOT_A_GIT_CHECKOUT`, `DETACHED_HEAD`, `NO_TARGET_REF`, `UNSUPPORTED_REF`,
`UNSUPPORTED_REPOSITORY_ID`, `STATE_INSIDE_REPOSITORY`, `REDIRECTED_STATE_COMPONENT`,
`STATE_COMPONENT_NOT_DIRECTORY`, `STATE_NOT_PRIVATE`, `STATE_UNAVAILABLE`), with a fixed
`hint` saying what to do, for example "check out a branch, then call again; no reconnect is
needed". Git-state codes are `retryable: true`. Details go to `launch.log` only.

### Core session server (`gauntlet-core`)

Exposes the same four author tools with the same request schemas; arguments become
`{"request": <unchanged>, "checkout": <optional>}`. Each binding gets its own `ReviewCore`
(the existing `GitSource` and `Store` for that tuple, participant `claude-author`, role
`author`), opened on first use and reused while the tuple is unchanged. At most 16 are kept;
the least recently used one that no call is using is closed to make room, and if all 16 are in
use the call fails with `BUSY`. The response is the core's unchanged envelope plus `binding`,
checked against the same `mcp_result_bytes` limit (`LIMIT_EXCEEDED` when over).

### Peer session server (`gauntlet-peer`)

`codex_status` and `codex_review` accept the same optional `checkout`. Each binding gets its
own adapter `Bridge` (its own instance ID and SDK conversation, participant `claude-peer`,
the operator's timeout settings), created by the first status or review call for it without
starting a model turn. Status and review responses carry `binding`.

If `codex_review` carries an instance ID that belongs to another binding of this process, it
fails with `BINDING_CHANGED` (naming both bindings) and starts no turn, so a branch switch
between status and review can never send a turn to the wrong branch or masquerade as a
restart. An unknown instance ID keeps today's `ADAPTER_RESTARTED` behavior. At most 8 bridges
are kept; the least recently used idle one is closed (within the adapter's cleanup deadline)
to make room, and with none idle the call fails with `LIMIT_EXCEEDED`. Server shutdown closes
every bridge.

### Trust boundary

The explicit-tuple servers keep the rule that clients cannot select repositories, refs or
state. The session servers relax exactly one thing for the **author host**: it may name a
checkout. Refs are still derived from that checkout (never supplied), the state path is still
derived under the operator's state root, and identity, role, executables, models and
permissions remain fixed. Naming a checkout grants nothing beyond what starting a session in
that folder already grants the same user and agent. The Codex reviewer cannot reach these
tools; the reviewer core registered for each thread stays a fixed tuple.

### Logging

`launch.log` gets one `core session cwd=...` or `peer session cwd=...` line at startup, one
`bind` line (checkout, repository ID, refs, state directory) the first time a process opens a
binding, and one line per refused call. The existing size bound applies.

### Installer: shadowing registrations

After a successful user-scope registration, `Register-GauntletMcp` reads the per-project
definitions of both names in the same configuration. It saves them to a backup only the
current user can read (the existing `Save-GauntletMcpBackup`), then removes each with
`claude mcp remove <name> -s local` run in that project's folder, and reads the configuration
back. The result reports the removed project paths, any left in place (folder missing, or the
command could not reach the entry) and the backup path; definitions are never printed. A
failed removal is a warning, not an install failure. `install.ps1 -KeepProjectOverrides` only
reports them.

### Documentation and skills

`docs/collaborative-mcp.md` (Global registration) and the `gauntlet-review` skill and
reference say: pass `checkout` with your working folder whenever it is not the session
folder, check `binding` before trusting a result, and never ask the operator to reconnect for
a branch or worktree change (a reconnect is for a failed server or a package upgrade). Do not
add project or local Gauntlet registrations.

## Compatibility and rollout

- Same derivation, same store directory names: existing launcher stores are reused.
- `codex_status` with `{}` and every existing request body still work; responses gain
  `binding`.
- The explicit-tuple entry points and their tests are unchanged.
- Rollout: update the installed source checkout the MCP venv's editable install points at,
  then run `install.ps1`. Sessions started before that keep their old servers until their
  next start, which is the last reconnect this needs.

## Testing

- Session core server through the in-memory MCP client against real Git fixtures: a branch
  switch between calls binds the new branch with no restart; `checkout` reaches a linked
  worktree; a non-checkout session folder and a detached HEAD give per-call errors and later
  calls succeed; invalid `checkout` values are refused; the store directory equals
  `launch.derive`'s; the cache bound and in-use protection hold.
- Session peer server with a fake conversation: per-binding instance IDs, `BINDING_CHANGED`
  with no turn, `ADAPTER_RESTARTED` for an unknown instance, idle eviction and the bound.
- Launcher: startup no longer refuses for Git state; state-root, pin and timeout refusals
  are unchanged.
- Installer: shadowing entries are backed up and removed, unreachable ones are reported,
  `-KeepProjectOverrides` changes nothing, and no definition appears in any message.
