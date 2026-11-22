"""Session servers: one host registration, a binding derived on every call.

The launcher starts these instead of a fixed-tuple server. Their only fixed value is the operator's state root:
the host may start them in a folder that is not the agent's (a desktop worktree session's servers can start in
the repository's main checkout), so every tool takes the agent's `checkout` and the server derives the binding
(checkout, repository ID, source and target refs, private state directory) from that folder on each call with
`launch.derive`, exactly as a launcher process did once at startup. A branch switch or another worktree takes effect
on the next call; nothing needs a reconnect. Each reply carries `binding`. Importing this module needs only stdlib.
"""
from __future__ import annotations

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
