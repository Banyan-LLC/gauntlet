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
