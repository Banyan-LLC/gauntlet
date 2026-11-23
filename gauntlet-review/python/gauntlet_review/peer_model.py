"""The operator's choice of Codex peer model and reasoning effort.

Gauntlet's own default is DEFAULT_MODEL at DEFAULT_EFFORT; the adapter always passes both to the SDK, so the
native Codex configuration never decides the reviewer. The operator can change either field globally or for one
repository in <state-root>/peer-model.json (version 1):

    {"version": 1, "default": {"effort": "max"}, "repositories": {"owner-repo": {"model": "gpt-6-sol"}}}

Each field resolves on its own: the repository's value, else the global value, else the built-in default. Only the
operator commands (gauntlet_review.model_cli) write the file; the adapter reads it fresh for every turn and status.
Reads refuse anything but a regular file at open time; writes are validated in full, then replace the file
atomically. Stdlib only."""
from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import stat
import time
from types import MappingProxyType
from typing import Mapping
import uuid

DEFAULT_MODEL = "gpt-6.1-sol"
DEFAULT_EFFORT = "xhigh"
SETTINGS_NAME = "peer-model.json"
SETTINGS_BYTES = 64 * 1024
MAX_REPOSITORIES = 256
FIELDS = ("model", "effort")
VERSION = 1
MODEL_RE = re.compile(r"[A-Za-z0-9_./:-]{1,128}\Z")
EFFORT_RE = re.compile(r"[a-z]{1,32}\Z")
REPOSITORY_RE = re.compile(r"[A-Za-z0-9_-]{1,64}\Z")
REPLACE_ATTEMPTS = 5
RETRY_DELAY = 0.05
_RULES = {"model": MODEL_RE, "effort": EFFORT_RE}
_replace = os.replace


class SettingsError(Exception):
    """code is a fixed structured code; detail is for the operator's own terminal and log only."""
    def __init__(self, code, detail=""):
        super().__init__(code)
        self.code = code
        self.detail = detail


def _invalid(detail):
    return SettingsError("MODEL_SETTINGS_INVALID", detail)


@dataclass(frozen=True)
class Selection:
    model: str
    effort: str
    model_source: str
    effort_source: str

    def public(self):
        return {"model": self.model, "model_source": self.model_source,
                "effort": self.effort, "effort_source": self.effort_source}


@dataclass(frozen=True)
class Settings:
    default: Mapping[str, str]
    repositories: Mapping[str, Mapping[str, str]]

    def __post_init__(self):
        object.__setattr__(self, "default", MappingProxyType(dict(self.default)))
        object.__setattr__(self, "repositories", MappingProxyType(
            {key: MappingProxyType(dict(value)) for key, value in self.repositories.items()}))


EMPTY = Settings({}, {})


def fixed(model, effort):
    """The selection for an adapter started with explicit --model/--effort values (either may be None)."""
    return Selection(model or DEFAULT_MODEL, effort or DEFAULT_EFFORT,
                     "operator" if model else "built_in", "operator" if effort else "built_in")


def resolve(settings, repository_id):
    entry = settings.repositories.get(repository_id, {}) if repository_id is not None else {}
    values, sources = {}, {}
    for field, builtin in (("model", DEFAULT_MODEL), ("effort", DEFAULT_EFFORT)):
        if field in entry:
            values[field], sources[field] = entry[field], "repository"
        elif field in settings.default:
            values[field], sources[field] = settings.default[field], "global"
        else:
            values[field], sources[field] = builtin, "built_in"
    return Selection(values["model"], values["effort"], sources["model"], sources["effort"])


def scope_name(repository_id):
    return "global" if repository_id is None else f"repository:{repository_id}"


def with_fields(settings, repository_id, *, model=None, effort=None):
    changes = {field: value for field, value in (("model", model), ("effort", effort)) if value is not None}
    default, repositories = dict(settings.default), {key: dict(value) for key, value in settings.repositories.items()}
    if repository_id is None:
        default.update(changes)
    else:
        repositories.setdefault(repository_id, {}).update(changes)
    return Settings(default, repositories)


def without_fields(settings, repository_id, fields):
    default, repositories = dict(settings.default), {key: dict(value) for key, value in settings.repositories.items()}
    entry = default if repository_id is None else repositories.get(repository_id, {})
    for field in fields:
        entry.pop(field, None)
    if repository_id is not None and repository_id in repositories and not entry:
        del repositories[repository_id]
    return Settings(default, repositories)


def to_document(settings):
    document = {"version": VERSION}
    if settings.default:
        document["default"] = dict(sorted(settings.default.items()))
    if settings.repositories:
        document["repositories"] = {key: dict(sorted(settings.repositories[key].items()))
                                    for key in sorted(settings.repositories)}
    return document


def encode_document(settings):
    return (json.dumps(to_document(settings), indent=2, ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")


def _entry(value, where):
    if not isinstance(value, dict) or not value:
        raise _invalid(f"{where} must be a non-empty object")
    for field, item in value.items():
        if field not in _RULES:
            raise _invalid(f"{where} has an unknown key")
        if type(item) is not str or not _RULES[field].fullmatch(item):
            raise _invalid(f"{where}.{field} is not a valid {field}")
    return value


def _validate(document):
    if not isinstance(document, dict):
        raise _invalid("the settings must be a JSON object")
    if set(document) - {"version", "default", "repositories"}:
        raise _invalid("unknown top-level key")
    if type(document.get("version")) is not int or document["version"] != VERSION:
        raise _invalid(f"version must be {VERSION}")
    default = _entry(document["default"], "default") if "default" in document else {}
    repositories = document.get("repositories", {})
    if not isinstance(repositories, dict):
        raise _invalid("repositories must be an object")
    if len(repositories) > MAX_REPOSITORIES:
        raise _invalid(f"more than {MAX_REPOSITORIES} repositories")
    for key, value in repositories.items():
        if not REPOSITORY_RE.fullmatch(key):
            raise _invalid("a repository ID is not valid")
        _entry(value, f"repositories.{key}")
    return Settings(default, repositories)


def _pairs(pairs):
    keys = [key for key, _ in pairs]
    if len(keys) != len(set(keys)):
        raise _invalid("duplicate key")
    return dict(pairs)


def _constant(name):
    raise _invalid(f"{name} is not allowed")


# --- reading without following ------------------------------------------------------------------------------------

def _handle_attributes(handle):
    """The Windows file attributes of an open handle (replaceable in tests)."""
    import ctypes
    from ctypes import wintypes

    class Info(ctypes.Structure):
        _fields_ = [("attributes", wintypes.DWORD), ("created", wintypes.FILETIME),
                    ("accessed", wintypes.FILETIME), ("written", wintypes.FILETIME),
                    ("volume", wintypes.DWORD), ("size_high", wintypes.DWORD), ("size_low", wintypes.DWORD),
                    ("links", wintypes.DWORD), ("index_high", wintypes.DWORD), ("index_low", wintypes.DWORD)]

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.GetFileInformationByHandle.argtypes = [wintypes.HANDLE, ctypes.POINTER(Info)]
    kernel32.GetFileInformationByHandle.restype = wintypes.BOOL
    info = Info()
    if not kernel32.GetFileInformationByHandle(handle, ctypes.byref(info)):
        raise ctypes.WinError(ctypes.get_last_error())
    return info.attributes


def _open_windows(path):
    import ctypes
    from ctypes import wintypes
    import msvcrt
    GENERIC_READ, OPEN_EXISTING, FILE_TYPE_DISK = 0x80000000, 3, 1
    SHARE_ALL = 0x1 | 0x2 | 0x4
    FLAGS = 0x00200000 | 0x02000000            # FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS
    REFUSED = 0x400 | 0x10                     # FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                                     wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel32.CreateFileW.restype = wintypes.HANDLE
    kernel32.GetFileType.argtypes = [wintypes.HANDLE]
    kernel32.GetFileType.restype = wintypes.DWORD
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel32.CreateFileW(str(path), GENERIC_READ, SHARE_ALL, None, OPEN_EXISTING, FLAGS, None)
    if handle is None or handle == ctypes.c_void_p(-1).value:
        error = ctypes.get_last_error()
        if error in (2, 3):                    # ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND
            return None
        raise ctypes.WinError(error)
    try:
        if kernel32.GetFileType(handle) != FILE_TYPE_DISK:
            raise _invalid("the settings file is not a disk file")
        if _handle_attributes(handle) & REFUSED:
            raise _invalid("the settings file is a link, reparse point or directory")
        return msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY)
    except BaseException:
        kernel32.CloseHandle(handle)
        raise


def _open_posix(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise _invalid(f"the settings file cannot be opened without following it: {error}") from error
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise _invalid("the settings file is not a regular file")
    return fd


def read_regular_nofollow(path, limit):
    """The bytes of a regular file (at most limit + 1 of them), None when it does not exist. The check is made on
    the opened handle, so nothing swapped in after a check can be read or block the read."""
    try:
        fd = _open_windows(path) if os.name == "nt" else _open_posix(path)
    except SettingsError:
        raise
    except OSError as error:
        raise _invalid(f"the settings file cannot be read: {error}") from error
    if fd is None:
        return None
    try:
        chunks, size = [], 0
        while size <= limit:
            chunk = os.read(fd, limit + 1 - size)
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        return b"".join(chunks)
    except OSError as error:
        raise _invalid(f"the settings file cannot be read: {error}") from error
    finally:
        os.close(fd)


def load(root):
    from gauntlet_review.launch import LaunchRefused, check_unredirected
    root = Path(root)
    try:
        check_unredirected(root)
    except LaunchRefused as error:
        raise _invalid(f"{error.code}: {error.detail}") from error
    except OSError as error:
        raise _invalid(f"the state root cannot be checked: {error}") from error
    data = read_regular_nofollow(root / SETTINGS_NAME, SETTINGS_BYTES)
    if data is None:
        return EMPTY
    if len(data) > SETTINGS_BYTES:
        raise _invalid(f"the settings file is larger than {SETTINGS_BYTES} bytes")
    try:
        document = json.loads(data.decode("utf-8-sig", "strict"), object_pairs_hook=_pairs,
                              parse_constant=_constant)
    except UnicodeError as error:
        raise _invalid("the settings file is not UTF-8") from error
    except RecursionError as error:
        # A document within the byte limit can still nest deeply enough to exhaust the parser.
        raise _invalid("the settings file is nested too deeply") from error
    except ValueError as error:
        raise _invalid(f"the settings file is not JSON: {error}") from error
    return _validate(document)


def selection_for(root, repository_id):
    return resolve(load(root), repository_id)


# --- writing ------------------------------------------------------------------------------------------------------

def _write_new(path, data):
    with open(path, "xb") as handle:
        handle.write(data)


def save(root, settings):
    """Validates the complete candidate and its exact bytes, then replaces the file atomically. A refused candidate
    (SettingsError, code CONFIGURATION_ERROR) touches nothing; other failures leave the previous file in place."""
    from gauntlet_review.launch import ensure_private_dir
    root = Path(root)
    try:
        _validate(to_document(settings))
    except SettingsError as error:
        raise SettingsError("CONFIGURATION_ERROR", error.detail) from error
    data = encode_document(settings)
    if len(data) > SETTINGS_BYTES:
        raise SettingsError("CONFIGURATION_ERROR",
                            f"the settings would be {len(data)} bytes, over the {SETTINGS_BYTES}-byte limit")
    ensure_private_dir(root)
    temporary = root / f"{SETTINGS_NAME}.{uuid.uuid4().hex}.tmp"
    try:
        _write_new(temporary, data)
        if os.name != "nt":
            os.chmod(temporary, 0o600)
        for attempt in range(REPLACE_ATTEMPTS):
            try:
                _replace(temporary, root / SETTINGS_NAME)
                break
            except PermissionError:
                # A Windows reader holding the file open makes the replace fail briefly.
                if attempt == REPLACE_ATTEMPTS - 1:
                    raise
                time.sleep(RETRY_DELAY)
    except BaseException:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise
