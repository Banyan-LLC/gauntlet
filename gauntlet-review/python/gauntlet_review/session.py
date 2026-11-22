"""Session servers: one host registration, a binding derived on every call.

The launcher starts these instead of a fixed-tuple server. Their only fixed value is the operator's state root:
the host may start them in a folder that is not the agent's (a desktop worktree session's servers can start in
the repository's main checkout), so every tool takes the agent's `checkout` and the server derives the binding
(checkout, repository ID, source and target refs, private state directory) from that folder on each call with
`launch.derive`, exactly as a launcher process did once at startup. A branch switch or another worktree takes effect
on the next call; nothing needs a reconnect. Each reply carries `binding`. Importing this module needs only stdlib.
"""
from __future__ import annotations

from collections import OrderedDict
from contextlib import asynccontextmanager, contextmanager
import os
from pathlib import Path
import re
import subprocess
import uuid

from gauntlet_review import launch

CHECKOUT_BYTES = 4096
CORE_BINDINGS = 16
PEER_BINDINGS = 8
MISSING = object()                       # a call that has no checkout argument at all
RETRYABLE = frozenset(("NOT_A_GIT_CHECKOUT", "DETACHED_HEAD", "NO_TARGET_REF"))
_STATE_HINT = "The operator's Gauntlet state root is unusable; the operator should check launch.log."
HINTS = {
    "checkout_required": "Pass checkout: the absolute path of your current working folder (the worktree you are "
                         "working in). Every call needs it; a branch or worktree change never needs a reconnect.",
    "invalid_checkout": "checkout must be an absolute local path in native form (a drive-letter path on Windows), "
                        "with no control characters.",
    "NOT_A_GIT_CHECKOUT": "That folder is not inside a Git checkout. Pass checkout: the absolute path of the worktree "
                          "you are working in.",
    "DETACHED_HEAD": "The checkout has a detached HEAD. Check out a branch (for example git switch -c review/name), "
                     "then call again; no reconnect is needed.",
    "NO_TARGET_REF": "The checkout has no origin default branch (refs/remotes/origin/HEAD, main or master). Fetch "
                     "origin, then call again; no reconnect is needed.",
    "UNSUPPORTED_REF": "The branch or target name is not valid UTF-8; use a branch with a UTF-8 name.",
    "UNSUPPORTED_REPOSITORY_ID": "No valid repository ID can be derived from origin's URL or the folder name.",
    "INTERNAL_ERROR": "Unexpected failure; the operator can find the correlation ID in launch.log.",
}
_WINDOWS_ABSOLUTE = re.compile(r"[A-Za-z]:\\")


class BindingError(Exception):
    """A call whose binding could not be derived. code is a launcher code or INVALID_ARGUMENT (with reason)."""
    def __init__(self, code, reason=None, correlation_id=None):
        super().__init__(code)
        self.code = code
        self.reason = reason or ("binding" if code != "INVALID_ARGUMENT" else "invalid_checkout")
        self.hint = HINTS.get(reason or code, _STATE_HINT)
        self.retryable = code in RETRYABLE
        self.correlation_id = correlation_id


def local_absolute(value, *, windows=None):
    """A local absolute path in native form, judged on the raw string. Windows: after treating / as \\, a drive
    letter, colon and root, which rules out every UNC and device form whatever the separators, rooted paths without
    a drive and drive-relative paths. POSIX: exactly one leading / and no backslash."""
    windows = os.name == "nt" if windows is None else windows
    if windows:
        return _WINDOWS_ABSOLUTE.match(value.replace("/", "\\")) is not None
    return value.startswith("/") and not value.startswith("//") and "\\" not in value


def public(bound):
    """The binding as replies show it. The state directory is never shown."""
    return {"checkout": str(bound.repo), "repository_id": bound.repository_id,
            "source_ref": bound.source_ref.decode("utf-8"), "target_ref": bound.target_ref.decode("utf-8")}


class Resolver:
    def __init__(self, role, state_root):
        self.role = role
        self.state_root = Path(state_root)
        self._bound = set()

    def folder(self, checkout):
        if checkout is MISSING or checkout is None:
            raise BindingError("INVALID_ARGUMENT", "checkout_required")
        if type(checkout) is not str:
            raise BindingError("INVALID_ARGUMENT", "invalid_checkout")
        try:
            size = len(checkout.encode("utf-8", "strict"))
        except UnicodeError:
            raise BindingError("INVALID_ARGUMENT", "invalid_checkout") from None
        if (size > CHECKOUT_BYTES or any(ord(ch) < 32 or ord(ch) == 127 for ch in checkout)
                or not local_absolute(checkout)):
            raise BindingError("INVALID_ARGUMENT", "invalid_checkout")
        return Path(checkout)

    def _refuse(self, code, detail, folder, correlation_id=None):
        note = f" correlation_id={correlation_id}" if correlation_id else ""
        launch._log(self.state_root, f"{self.role} refused {code}{note}: {detail} (checkout={folder})")
        return BindingError(code, correlation_id=correlation_id)

    def resolve(self, checkout=MISSING):
        """The binding for this call's checkout, its private state directory made. Raises BindingError."""
        folder = self.folder(checkout)          # an invalid value is refused before any filesystem access
        failures = []
        try:
            if not folder.is_dir():
                raise launch.LaunchRefused("NOT_A_GIT_CHECKOUT", f"{folder} is not a directory")
            bound = launch.derive(folder, self.state_root)
            launch.ensure_private_dir(bound.state_dir, failures)
        except launch.LaunchRefused as refusal:
            raise self._refuse(refusal.code, refusal.detail + launch._cleanup_note(failures), folder) from None
        except subprocess.SubprocessError as error:
            raise self._refuse("STATE_NOT_PRIVATE", f"{type(error).__name__}: {error}" + launch._cleanup_note(failures),
                               folder) from None
        except OSError as error:
            raise self._refuse("STATE_UNAVAILABLE", f"{type(error).__name__}: {error}" + launch._cleanup_note(failures),
                               folder) from None
        except Exception as error:
            raise self._refuse("INTERNAL_ERROR", f"{type(error).__name__}: {error}", folder, uuid.uuid4().hex) from None
        if bound not in self._bound:
            self._bound.add(bound)
            launch._log(self.state_root, f"{self.role} bind checkout={bound.repo} id={bound.repository_id} "
                                         f"source={bound.source_ref.decode()} target={bound.target_ref.decode()} "
                                         f"state={bound.state_dir}")
        return bound


CHECKOUT_SENTENCE = (" checkout (required): the absolute path of your current working folder; every call follows that "
                     "checkout's current branch, shown in binding. A branch or worktree change never needs a reconnect.")
INSTRUCTIONS_SUFFIX = (" Each call follows the checkout's current branch: pass checkout (your current working folder) on "
                       "every call and check binding. A branch or worktree change never needs a reconnect.")


def _binding_detail(error):
    detail = {"reason": error.reason, "hint": error.hint}
    if error.correlation_id:
        detail["correlation_id"] = error.correlation_id
    return detail


class _CorePool:
    """At most `limit` open review cores, one per binding. acquire/release never await, so on the event loop no
    other call interleaves inside them. A full pool closes its least recently used idle core; with every core in
    use, admission is BUSY."""
    def __init__(self, open_core, limit):
        self._open = open_core
        self.limit = limit
        self.entries = OrderedDict()                # binding -> [core, users]

    def acquire(self, key):
        from gauntlet_review.collaborative.contracts import CoreError
        entry = self.entries.get(key)
        if entry is not None:
            self.entries.move_to_end(key)
            entry[1] += 1
            return entry[0]
        if len(self.entries) >= self.limit:
            victim = next((name for name, (_, users) in self.entries.items() if users == 0), None)
            if victim is None:
                raise CoreError("BUSY", retryable=True, detail={"reason": "bindings_in_use"})
            self.entries.pop(victim)[0].close()
        core = self._open(key)
        self.entries[key] = [core, 1]
        return core

    def release(self, key):
        entry = self.entries.get(key)
        if entry is not None:
            entry[1] -= 1

    @contextmanager
    def lease(self, key):
        core = self.acquire(key)
        try:
            yield core
        finally:                                     # success, error and cancellation alike
            self.release(key)

    def close(self):
        entries, self.entries = list(self.entries.values()), OrderedDict()
        failure = None
        for core, _ in entries:
            try:
                core.close()
            except Exception as error:               # close the rest; report the first failure
                failure = failure or error
        if failure is not None:
            raise failure


def create_core_server(resolver):
    """The author core session server: the four author tools; arguments {"request": ..., "checkout": ...}."""
    from gauntlet_review.collaborative import server as core_server
    core_server._require_extra()
    from importlib import metadata
    from mcp.server.lowlevel import Server
    from mcp.shared.exceptions import MCPError
    from mcp_types import ListToolsResult, Tool, INVALID_PARAMS
    from pydantic import ValidationError
    from gauntlet_review.collaborative.contracts import ASSURANCE, CoreError, OperatorConfig, Policy
    from gauntlet_review.collaborative.core import ROLE_TOOLS, ReviewCore
    from gauntlet_review.collaborative.source import GitSource
    from gauntlet_review.collaborative.store import Store

    core_server._safe_logging()
    names = sorted(ROLE_TOOLS["author"])
    arguments = core_server.argument_models({"checkout": (str, ...)})
    limit = Policy().mcp_result_bytes

    def envelope(code, retryable=False, detail=None):
        # The keys ReviewCore._envelope produces for an error with no review context.
        return {"ok": False, "assurance": ASSURANCE, "review_id": None, "revision_id": None, "snapshot_digest": None,
                "store_version": None, "freshness": {"state": "unknown"}, "result": None,
                "error": {"code": code, "retryable": retryable, "detail": detail or {}}}

    def reply(payload, binding):
        built = core_server.tool_result({**payload, "binding": binding}, limit)
        if built is None:
            built = core_server.tool_result({**envelope("LIMIT_EXCEEDED", detail={"limit": "mcp_result_bytes"}),
                                             "binding": binding}, float("inf"))
        return built

    def open_core(bound):
        config = OperatorConfig(bound.repo, bound.state_dir, bound.repository_id, bound.source_ref, bound.target_ref,
                                "claude-author", "author")
        source = GitSource(config)
        try:
            store = Store.open(config, source.repo_binding)
            try:
                return ReviewCore(config, source, store, Policy())
            except BaseException:
                store.close()
                raise
        except BaseException:
            source.close()
            raise

    @asynccontextmanager
    async def lifetime(_):
        pool = _CorePool(open_core, CORE_BINDINGS)
        try:
            yield pool
        finally:
            pool.close()

    async def list_tools(context, params):
        return ListToolsResult(tools=[Tool(name=name, description=core_server.DESCRIPTIONS[name] + CHECKOUT_SENTENCE,
                                           input_schema=arguments[name].model_json_schema()) for name in names])

    async def call_tool(context, params):
        pool = context.lifespan_context
        if params.name not in names:
            raise MCPError(INVALID_PARAMS, "Unknown tool")
        raw = params.arguments
        if not isinstance(raw, dict):
            return reply(envelope("INVALID_ARGUMENT", detail={"reason": "invalid_request"}), None)
        try:
            resolver.folder(raw.get("checkout", MISSING))        # checkout first: required, local and absolute
        except BindingError as error:
            return reply(envelope(error.code, error.retryable, _binding_detail(error)), None)
        try:
            parsed = arguments[params.name].model_validate(raw, strict=True)
        except ValidationError:
            return reply(envelope("INVALID_ARGUMENT", detail={"reason": "invalid_request"}), None)
        try:
            bound = resolver.resolve(parsed.checkout)
        except BindingError as error:
            return reply(envelope(error.code, error.retryable, _binding_detail(error)), None)
        binding = public(bound)
        try:
            with pool.lease(bound) as core:
                try:
                    # Only the four fixed author names reach getattr.
                    payload = await getattr(core, params.name)(parsed.request)
                except CoreError as error:
                    payload = core.error_response(error)
                except Exception:
                    payload = core.error_response(CoreError("INTERNAL_ERROR",
                                                            detail={"correlation_id": uuid.uuid4().hex}))
        except CoreError as error:                               # admission: BUSY, or the core could not open
            payload = envelope(error.code, error.retryable, error.detail)
        except Exception:
            payload = envelope("INTERNAL_ERROR", detail={"correlation_id": uuid.uuid4().hex})
        return reply(payload, binding)

    return Server("gauntlet-collaborative", version=metadata.version("gauntlet-review"),
                  description="Local collaborative-v1 review records and policy, bound per call to the agent's checkout.",
                  instructions="Native hosts own conversations and tool permissions. Peer completion records a fresh "
                               "local review; it is not CI success, hermetic certification, human approval or merge "
                               "permission." + INSTRUCTIONS_SUFFIX,
                  lifespan=lifetime, on_list_tools=list_tools, on_call_tool=call_tool)


def serve(server):
    """Runs a session server over stdio until the host disconnects, as the fixed-tuple servers' entry points do.
    Unexpected failures print one fixed code with a correlation ID, never a traceback."""
    import json
    import sys
    import anyio
    from mcp.server.stdio import stdio_server
    from gauntlet_review.collaborative.server import _safe_logging
    _safe_logging(root=True)

    async def run():
        async with stdio_server() as (read, write):
            await server.run(read, write, server.create_initialization_options())
    try:
        anyio.run(run)
        return 0
    except KeyboardInterrupt:
        return 130
    except Exception:
        try:
            sys.stderr.write(json.dumps({"code": "INTERNAL_ERROR", "operation": "serve",
                                         "correlation_id": uuid.uuid4().hex}, separators=(",", ":")) + "\n")
        except (OSError, ValueError):
            pass
        return 2


def _consume(task):
    if not task.cancelled():
        task.exception()


class _PeerPool:
    """At most `limit` adapter bridges, one per binding. One lock serializes admission from the capacity check to
    the insert, so overlapping calls can neither exceed the bound nor make two bridges for one binding. Bridge.close
    marks a bridge closed before it awaits, so an interrupted close could never be retried: the pool runs every
    close as its own task, kept in `closing` until it finishes. An evicting call only waits for that task (bounded,
    shielded from the caller's cancellation), and close() waits for whatever is still closing. Once close() starts,
    every admission is refused (cause shutdown), and the teardown never waits for the admission lock, so admissions
    queued behind a slow eviction cannot delay it."""
    def __init__(self, create, limit):
        import asyncio
        self._create = create
        self.limit = limit
        self.entries = OrderedDict()                # binding -> [bridge, users]
        self.closing = set()
        self._lock = asyncio.Lock()
        self._shutting_down = False
        self._teardown = None

    def owner(self, instance_id):
        for key, (bridge, _) in self.entries.items():
            if bridge.instance_id == instance_id:
                return key
        return None

    def _occupied(self):
        return len(self.entries) + len(self.closing)

    def _prune(self):
        for task in [task for task in self.closing if task.done()]:
            self.closing.discard(task)

    def _close_task(self, bridge):
        import asyncio
        task = asyncio.create_task(bridge.close())
        self.closing.add(task)
        task.add_done_callback(self.closing.discard)
        task.add_done_callback(_consume)
        return task

    @staticmethod
    async def _wait(tasks):
        import asyncio
        from gauntlet_review.codex_bridge.engine import CLEANUP_SECONDS
        if tasks:
            # asyncio.wait never cancels what it waits for: a cancelled or timed-out wait leaves the close running.
            await asyncio.wait(tasks, timeout=CLEANUP_SECONDS + 1)

    @asynccontextmanager
    async def lease(self, key):
        from gauntlet_review.codex_bridge.engine import BridgeError
        async with self._lock:
            if self._shutting_down:
                raise BridgeError("CANCELLED", cause="shutdown")
            entry = self.entries.get(key)
            if entry is not None:
                self.entries.move_to_end(key)
                entry[1] += 1
                bridge = entry[0]
            else:
                # A bridge still closing keeps its slot until its close task ends: live plus retiring bridges never
                # exceed the bound, even after an evicting call was cancelled mid-close.
                if self._occupied() >= self.limit and not self.closing:
                    victim = next((name for name, (candidate, users) in self.entries.items()
                                   if users == 0 and not candidate._busy), None)
                    if victim is None:
                        raise BridgeError("LIMIT_EXCEEDED", cause="bindings")
                    self._close_task(self.entries.pop(victim)[0])
                if self._occupied() >= self.limit:
                    await self._wait(set(self.closing))
                    self._prune()
                if self._shutting_down:                # shutdown began while this admission waited
                    raise BridgeError("CANCELLED", cause="shutdown")
                if self._occupied() >= self.limit:
                    raise BridgeError("LIMIT_EXCEEDED", cause="bindings")
                bridge = self._create(key)
                self.entries[key] = [bridge, 1]
        try:
            yield bridge
        finally:                                     # success, error and cancellation alike
            entry = self.entries.get(key)
            if entry is not None and entry[0] is bridge:
                entry[1] -= 1

    async def _close_all(self):
        # No admission lock: admissions are already refused (_shutting_down), and an admission still inside the lock
        # rechecks the flag before it inserts, so every bridge that will ever exist is in entries or closing here.
        import asyncio
        bridges, self.entries = [bridge for bridge, _ in self.entries.values()], OrderedDict()
        for bridge in bridges:
            self._close_task(bridge)
        pending = set(self.closing)
        await self._wait(pending)
        for task in pending:
            if not task.done():
                task.cancel()
        if pending:
            await asyncio.wait(pending, timeout=1)
        self._prune()

    async def close(self):
        """Closes every bridge and waits for every close still running, bounded. The teardown runs as its own task
        and the wait is protected from the caller's cancellation: an anyio shield for the lifespan's cancel scope,
        and for native cancellation a drain that absorbs every cancel (however many arrive) until the teardown ends
        or its deadline passes, and only then lets the first cancellation through. A cancelled shutdown never
        abandons a close."""
        import asyncio
        import anyio
        from gauntlet_review.codex_bridge.engine import CLEANUP_SECONDS
        loop = asyncio.get_running_loop()
        self._shutting_down = True                     # before any await: no admission gets past this point
        if self._teardown is None:
            self._teardown = asyncio.ensure_future(self._close_all())
            self._teardown.add_done_callback(_consume)     # observed even if every wait below gives up
        teardown = self._teardown
        deadline = loop.time() + 2 * CLEANUP_SECONDS + 3      # _close_all itself is bounded below this
        cancelled = None
        with anyio.CancelScope(shield=True):
            while not teardown.done():
                remaining = deadline - loop.time()
                if remaining <= 0:
                    break
                try:
                    # asyncio.wait never cancels the teardown it waits for.
                    await asyncio.wait({teardown}, timeout=remaining)
                except asyncio.CancelledError as error:
                    cancelled = cancelled or error
        if cancelled is not None:
            raise cancelled
        if teardown.done():
            teardown.result()


def _peer_error(code, cause, hint=None, correlation_id=None):
    error = {"code": code, "cause": cause, "correlation_id": correlation_id or uuid.uuid4().hex, "uncertain": False,
             "partial_usable": False, "thread_id": None, "turn_id": None,
             "cleanup": {"status": "not_attempted", "cause": None}}
    if hint:
        error["hint"] = hint
    return {"ok": False, "error": error}


def binding_reserve(binding):
    """RESULT_BYTES kept free per bridge so `binding` always fits beside a reply: it appears once in the structured
    copy and once in the text copy, where JSON string escaping can at most double it."""
    from gauntlet_review.codex_bridge.engine import _encode
    return 3 * len(_encode({"binding": binding})) + 64


def create_peer_server(resolver, timeout_seconds, extended_timeout, model=None):
    """The peer session server: codex_status {checkout} and codex_review {request fields..., checkout}."""
    from gauntlet_review.codex_bridge import server as peer_server
    peer_server._require_extra()
    from importlib import metadata
    from mcp.server.lowlevel import Server
    from mcp.shared.exceptions import MCPError
    from mcp_types import ListToolsResult, Tool, INVALID_PARAMS
    from gauntlet_review.collaborative.contracts import OperatorConfig
    from gauntlet_review.collaborative.server import _safe_logging
    from gauntlet_review.codex_bridge.engine import Bridge, BridgeConfig, BridgeError, ReviewRequest, mcp_result

    _safe_logging()
    checkout_schema = {"type": "string", "description": "Absolute path of your current working folder."}
    status_schema = {"type": "object", "properties": {"checkout": checkout_schema}, "required": ["checkout"],
                     "additionalProperties": False}
    review_schema = ReviewRequest.model_json_schema()
    review_schema["properties"]["checkout"] = checkout_schema
    review_schema["required"] = [*review_schema.get("required", []), "checkout"]

    def reply(payload, binding):
        try:
            return mcp_result({**payload, "binding": binding})
        except BridgeError:
            return mcp_result({**_peer_error("LIMIT_EXCEEDED", "binding_budget"), "binding": binding})

    def create(bound):
        config = BridgeConfig(OperatorConfig(bound.repo, bound.state_dir, bound.repository_id, bound.source_ref,
                                             bound.target_ref, "claude-peer", "reviewer"),
                              model=model, timeout_seconds=timeout_seconds, extended_timeout=extended_timeout,
                              result_reserve=binding_reserve(public(bound)))
        return Bridge(config, peer_server.SdkConversation(config))

    @asynccontextmanager
    async def lifetime(_):
        pool = _PeerPool(create, PEER_BINDINGS)
        try:
            yield pool
        finally:
            await pool.close()

    async def list_tools(context, params):
        return ListToolsResult(tools=[
            Tool(name="codex_status", description="Get the adapter instance, owned thread and state for this checkout's "
                 "binding without starting a model turn." + CHECKOUT_SENTENCE, input_schema=status_schema),
            Tool(name="codex_review", description="Run or exactly replay one Codex peer turn for this checkout's binding. "
                 "Echo the current instance and owned thread. After restart, stop and explicitly begin a fresh "
                 "conversation that rereads all existing review history and findings. Never silently replay uncertain "
                 "turns. Completion comes only from fresh core review_status." + CHECKOUT_SENTENCE,
                 input_schema=review_schema)])

    async def call_tool(context, params):
        pool = context.lifespan_context
        if params.name not in ("codex_status", "codex_review"):
            raise MCPError(INVALID_PARAMS, "Unknown tool")
        raw = params.arguments
        if not isinstance(raw, dict):
            return reply(_peer_error("INVALID_ARGUMENT", "validation"), None)
        try:
            resolver.folder(raw.get("checkout", MISSING))
        except BindingError as error:
            return reply(_peer_error(error.code, error.reason, error.hint), None)
        rest = {key: value for key, value in raw.items() if key != "checkout"}
        if params.name == "codex_status" and rest:
            return reply(_peer_error("INVALID_ARGUMENT", "validation"), None)
        try:
            bound = resolver.resolve(raw["checkout"])
        except BindingError as error:
            return reply(_peer_error(error.code, error.reason, error.hint, error.correlation_id), None)
        binding = public(bound)
        if params.name == "codex_review" and type(rest.get("instance_id")) is str:
            owner = pool.owner(rest["instance_id"])
            if owner is not None and owner != bound:            # never a turn on another branch's conversation
                return reply({**_peer_error("BINDING_CHANGED", "binding_changed"), "instance_binding": public(owner)},
                             binding)
        try:
            async with pool.lease(bound) as bridge:
                payload = bridge.status() if params.name == "codex_status" else await bridge.call(rest)
        except BridgeError as error:
            payload = _peer_error(error.code, error.cause)
        return reply(payload, binding)

    return Server("gauntlet-codex", version=metadata.version("gauntlet-review"),
                  instructions="One SDK conversation per checkout binding. Native authentication and runtime lifecycle "
                               "remain native-host responsibilities. Preserve existing core history after restart. No "
                               "automatic retry, approval or merge." + INSTRUCTIONS_SUFFIX,
                  lifespan=lifetime, on_list_tools=list_tools, on_call_tool=call_tool)
