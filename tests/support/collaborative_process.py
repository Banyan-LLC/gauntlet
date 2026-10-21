"""Test-only, stdlib process custody. Never imported by the installed service.

The external controller owns the job/group. Nested commands inherit its token,
deadline and cross-process capture reservations; they never create a new owner.
All receipts are create-only, including launch/cleanup failures.
"""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import asdict, dataclass, field
import base64
import ctypes
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import threading
import time
import uuid

CHUNK = 4096
CHANNEL_LIMITS = {"stdout": 4 * 1024 * 1024, "stderr": 4 * 1024 * 1024,
                  "control": 64 * 1024}
LAYER_LIMIT = 8 * 1024 * 1024
OWNER_ENV = "GAUNTLET_TEST_OWNER"
_NESTED_CHILDREN = set()


@dataclass(frozen=True)
class StageError:
    stage: str
    exception_type: str
    detail: str
    causes: tuple[str, ...] = ()

    @classmethod
    def from_exception(cls, stage, error):
        causes = []
        seen = set()
        cause = error.__cause__ or error.__context__
        while cause is not None and id(cause) not in seen and len(causes) < 4:
            seen.add(id(cause))
            causes.append(f"{type(cause).__name__}: {str(cause)[:256]}")
            cause = cause.__cause__ or cause.__context__
        pending = list(getattr(error, "exceptions", ()))
        while pending and len(causes) < 4:
            nested = pending.pop(0)
            if isinstance(nested, BaseExceptionGroup):
                pending.extend(nested.exceptions)
            else:
                causes.append(f"{type(nested).__name__}: {str(nested)[:256]}")
        return cls(stage, type(error).__name__, str(error)[:1024], tuple(causes))


@dataclass
class Capture:
    observed_bytes: int = 0
    retained_bytes: int = 0
    prefix: bytes = field(default=b"", repr=False)
    incomplete: bool = False
    error: StageError | None = None


@dataclass(frozen=True)
class ExpectedExit:
    exit_code: int = 0
    checkpoint: str | None = None

    def __post_init__(self):
        if type(self.exit_code) is not int:
            raise ValueError("expected exit must be an integer")
        if self.exit_code != 0 and not self.checkpoint:
            raise ValueError("nonzero expectation requires a predeclared checkpoint")
        if self.checkpoint is not None and (not self.checkpoint or
                                            len(self.checkpoint.encode("utf-8")) > 800):
            raise ValueError("invalid checkpoint")


@dataclass
class CommandOutcome:
    argv: list[str] = field(default_factory=list)
    cwd: str | None = None
    started_at_utc: str | None = None
    expected_exit: dict | None = None
    started: bool = False
    pid: int | None = None
    completed: bool = False
    exit_code: int | None = None
    timed_out: bool = False
    overflowed: bool = False
    cancelled: bool = False
    stdout: Capture = field(default_factory=Capture)
    stderr: Capture = field(default_factory=Capture)
    control: Capture = field(default_factory=Capture)
    stdin_delivered: bool = False
    termination_requested: bool = False
    termination_result: str | None = None
    root_reaped: bool = False
    tree_retired: bool = False
    readers_settled: bool = False
    writer_settled: bool = False
    errors: list[StageError] = field(default_factory=list)
    cleanup_errors: list[StageError] = field(default_factory=list)
    deadline: float = 0
    elapsed_seconds: float = 0
    expectation_match: bool = False
    fresh_owner: bool = False
    receipt_path: Path | None = None
    owner_token: str | None = None
    ownership_inventory: dict | None = None


class CommandFailure(RuntimeError):
    def __init__(self, outcome):
        self.outcome = outcome
        super().__init__(f"incomplete test command; receipt: {outcome.receipt_path}")


class CaptureOverflow(RuntimeError):
    pass


def owner_context():
    """Validate explicit inherited context before any nested child is launched."""
    raw = os.environ.get(OWNER_ENV)
    if not raw or len(raw) > 8192:
        raise RuntimeError("missing test ownership context")
    value = json.loads(raw)
    if set(value) != {"token", "deadline", "execution_deadline", "budget", "control",
                      "group", "controller", "receipts"}:
        raise RuntimeError("invalid test ownership context")
    if not isinstance(value["token"], str) or len(value["token"]) != 32:
        raise RuntimeError("invalid ownership token")
    if not math.isfinite(value["deadline"]) or value["deadline"] <= time.monotonic():
        raise TimeoutError("inherited owner deadline expired")
    with open(value["budget"], "rb", buffering=0) as stream:
        if stream.read(32) != value["token"].encode("ascii"):
            raise RuntimeError("ownership budget/token mismatch")
    if os.name == "posix" and os.getpgrp() != value["group"]:
        raise RuntimeError("nested process escaped owner group")
    if os.name == "nt" and not _in_job(value["token"]):
        raise RuntimeError("nested process is outside an owner job")
    return value


class Budget:
    def __init__(self, path, token, *, deadline, create=False):
        self.path = Path(path)
        self.deadline = deadline
        if create:
            with self.path.open("xb") as stream:
                stream.write(token.encode("ascii") + struct.pack("<QQ", 0, 0) + b"\0")
        self.token = token

    def reserve(self, layer, size):
        with self.path.open("r+b", buffering=0) as stream:
            while True:
                try:
                    if os.name == "nt":
                        import msvcrt
                        stream.seek(48)
                        msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                    else:
                        import fcntl
                        fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError as exception:
                    if exception.errno not in (11, 13, 35):
                        raise
                    if time.monotonic() >= self.deadline:
                        raise TimeoutError("capture reservation deadline expired") from exception
                    time.sleep(min(.001, max(0, self.deadline - time.monotonic())))
            try:
                stream.seek(0)
                if stream.read(32) != self.token.encode("ascii"):
                    raise RuntimeError("capture budget token mismatch")
                counts = list(struct.unpack("<QQ", stream.read(16)))
                if counts[layer] + size < 0:
                    raise RuntimeError("invalid capture reservation release")
                if counts[layer] + size > LAYER_LIMIT or sum(counts) + size > 2 * LAYER_LIMIT:
                    raise CaptureOverflow("shared retained capture budget exceeded")
                counts[layer] += size
                stream.seek(32)
                stream.write(struct.pack("<QQ", *counts))
            finally:
                if os.name == "nt":
                    stream.seek(48)
                    msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


if os.name == "nt":
    from ctypes import wintypes as W
    K = ctypes.WinDLL("kernel32", use_last_error=True)
    SIZE_T = ctypes.c_size_t

    class SECURITY_ATTRIBUTES(ctypes.Structure):
        _fields_ = [("nLength", W.DWORD), ("lpSecurityDescriptor", W.LPVOID),
                    ("bInheritHandle", W.BOOL)]

    class STARTUPINFO(ctypes.Structure):
        _fields_ = [("cb", W.DWORD), ("lpReserved", W.LPWSTR), ("lpDesktop", W.LPWSTR),
                    ("lpTitle", W.LPWSTR), ("dwX", W.DWORD), ("dwY", W.DWORD),
                    ("dwXSize", W.DWORD), ("dwYSize", W.DWORD), ("dwXCountChars", W.DWORD),
                    ("dwYCountChars", W.DWORD), ("dwFillAttribute", W.DWORD),
                    ("dwFlags", W.DWORD), ("wShowWindow", W.WORD), ("cbReserved2", W.WORD),
                    ("lpReserved2", ctypes.POINTER(ctypes.c_byte)),
                    ("hStdInput", W.HANDLE), ("hStdOutput", W.HANDLE), ("hStdError", W.HANDLE)]

    class PROCESS_INFORMATION(ctypes.Structure):
        _fields_ = [("hProcess", W.HANDLE), ("hThread", W.HANDLE),
                    ("dwProcessId", W.DWORD), ("dwThreadId", W.DWORD)]

    class BASIC_LIMIT(ctypes.Structure):
        _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64),
                    ("PerJobUserTimeLimit", ctypes.c_int64), ("LimitFlags", W.DWORD),
                    ("MinimumWorkingSetSize", SIZE_T), ("MaximumWorkingSetSize", SIZE_T),
                    ("ActiveProcessLimit", W.DWORD), ("Affinity", SIZE_T),
                    ("PriorityClass", W.DWORD), ("SchedulingClass", W.DWORD)]

    class IO_COUNTERS(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint64) for name in
                    ("ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                     "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

    class EXTENDED_LIMIT(ctypes.Structure):
        _fields_ = [("BasicLimitInformation", BASIC_LIMIT), ("IoInfo", IO_COUNTERS),
                    ("ProcessMemoryLimit", SIZE_T), ("JobMemoryLimit", SIZE_T),
                    ("PeakProcessMemoryUsed", SIZE_T), ("PeakJobMemoryUsed", SIZE_T)]

    class ACCOUNTING(ctypes.Structure):
        _fields_ = [(name, ctypes.c_int64) for name in
                    ("TotalUserTime", "TotalKernelTime", "ThisPeriodTotalUserTime",
                     "ThisPeriodTotalKernelTime")] + [(name, W.DWORD) for name in
                    ("TotalPageFaultCount", "TotalProcesses", "ActiveProcesses", "TotalTerminatedProcesses")]

    def _bind(name, args, result=W.BOOL):
        fn = getattr(K, name)
        fn.argtypes, fn.restype = args, result
        return fn

    _close = _bind("CloseHandle", [W.HANDLE])
    _create_pipe = _bind("CreatePipe", [ctypes.POINTER(W.HANDLE), ctypes.POINTER(W.HANDLE),
                                      ctypes.POINTER(SECURITY_ATTRIBUTES), W.DWORD])
    _handle_info = _bind("SetHandleInformation", [W.HANDLE, W.DWORD, W.DWORD])
    _peek = _bind("PeekNamedPipe", [W.HANDLE, W.LPVOID, W.DWORD, ctypes.POINTER(W.DWORD),
                                   ctypes.POINTER(W.DWORD), ctypes.POINTER(W.DWORD)])
    _read = _bind("ReadFile", [W.HANDLE, W.LPVOID, W.DWORD, ctypes.POINTER(W.DWORD), W.LPVOID])
    _write = _bind("WriteFile", [W.HANDLE, W.LPVOID, W.DWORD, ctypes.POINTER(W.DWORD), W.LPVOID])
    _create_job = _bind("CreateJobObjectW", [W.LPVOID, W.LPCWSTR], W.HANDLE)
    _open_job = _bind("OpenJobObjectW", [W.DWORD, W.BOOL, W.LPCWSTR], W.HANDLE)
    _set_job = _bind("SetInformationJobObject", [W.HANDLE, ctypes.c_int, W.LPVOID, W.DWORD])
    _query_job = _bind("QueryInformationJobObject", [W.HANDLE, ctypes.c_int, W.LPVOID, W.DWORD,
                                                   ctypes.POINTER(W.DWORD)])
    _assign_job = _bind("AssignProcessToJobObject", [W.HANDLE, W.HANDLE])
    _terminate_job = _bind("TerminateJobObject", [W.HANDLE, W.UINT])
    _terminate_process = _bind("TerminateProcess", [W.HANDLE, W.UINT])
    _resume = _bind("ResumeThread", [W.HANDLE], W.DWORD)
    _wait = _bind("WaitForSingleObject", [W.HANDLE, W.DWORD], W.DWORD)
    _exit_code = _bind("GetExitCodeProcess", [W.HANDLE, ctypes.POINTER(W.DWORD)])
    _create_process = _bind("CreateProcessW", [W.LPCWSTR, W.LPWSTR, W.LPVOID, W.LPVOID, W.BOOL,
                                              W.DWORD, W.LPVOID, W.LPCWSTR,
                                              ctypes.POINTER(STARTUPINFO),
                                              ctypes.POINTER(PROCESS_INFORMATION)])
    _is_in_job = _bind("IsProcessInJob", [W.HANDLE, W.HANDLE, ctypes.POINTER(W.BOOL)])
    _current_process = _bind("GetCurrentProcess", [], W.HANDLE)
    _open_process = _bind("OpenProcess", [W.DWORD, W.BOOL, W.DWORD], W.HANDLE)
    _image_name = _bind("QueryFullProcessImageNameW", [W.HANDLE, W.DWORD, W.LPWSTR,
                                                    ctypes.POINTER(W.DWORD)])
    class PROCESS_BASIC_INFORMATION(ctypes.Structure):
        _fields_ = [("ExitStatus", ctypes.c_long), ("PebBaseAddress", W.LPVOID),
                    ("AffinityMask", SIZE_T), ("BasePriority", ctypes.c_long),
                    ("UniqueProcessId", SIZE_T), ("InheritedFromUniqueProcessId", SIZE_T)]

    _query_process = ctypes.WinDLL("ntdll").NtQueryInformationProcess
    _query_process.argtypes = [W.HANDLE, ctypes.c_int, W.LPVOID, W.ULONG, ctypes.POINTER(W.ULONG)]
    _query_process.restype = ctypes.c_long

    def _check(result):
        if not result:
            raise ctypes.WinError(ctypes.get_last_error())
        return result

    def _in_job(token):
        answer = W.BOOL()
        handle = _check(_open_job(4, False, "Local\\GauntletTest-" + token))
        try:
            _check(_is_in_job(_current_process(), handle, ctypes.byref(answer)))
            return bool(answer.value)
        finally:
            _check(_close(handle))


class RawPipe:
    """Unbuffered handles; readers poll so an inherited pipe cannot block close."""
    def __init__(self, child_reads=False):
        self.eof = False
        self.parent_closed = False
        self.child_closed = False
        if os.name == "nt":
            attrs = SECURITY_ATTRIBUTES(ctypes.sizeof(SECURITY_ATTRIBUTES), None, True)
            rd, wr = W.HANDLE(), W.HANDLE()
            _check(_create_pipe(ctypes.byref(rd), ctypes.byref(wr), ctypes.byref(attrs), CHUNK))
            self.child, self.parent = (rd.value, wr.value) if child_reads else (wr.value, rd.value)
            _check(_handle_info(self.parent, 1, 0))
        else:
            rd, wr = os.pipe()
            self.child, self.parent = (rd, wr) if child_reads else (wr, rd)
            os.set_inheritable(self.child, True)
            if not child_reads:
                os.set_blocking(self.parent, False)

    def read(self):
        if self.eof:
            return b""
        if os.name == "nt":
            available = W.DWORD()
            if not _peek(self.parent, None, 0, None, ctypes.byref(available), None):
                if ctypes.get_last_error() in (109, 232):
                    self.eof = True
                    return b""
                raise ctypes.WinError(ctypes.get_last_error())
            if not available.value:
                return None
            buf = ctypes.create_string_buffer(min(CHUNK, available.value))
            count = W.DWORD()
            _check(_read(self.parent, buf, len(buf), ctypes.byref(count), None))
            return buf.raw[:count.value]
        try:
            value = os.read(self.parent, CHUNK)
        except BlockingIOError:
            return None
        if not value:
            self.eof = True
        return value

    def write(self, data):
        if os.name == "nt":
            count = W.DWORD()
            _check(_write(self.parent, data, len(data), ctypes.byref(count), None))
            return count.value
        return os.write(self.parent, data)

    def close_child(self):
        if not self.child_closed:
            _check(_close(self.child)) if os.name == "nt" else os.close(self.child)
            self.child_closed = True

    def close_parent(self):
        if not self.parent_closed:
            _check(_close(self.parent)) if os.name == "nt" else os.close(self.parent)
            self.parent_closed = True


class NativeChild:
    """Retain actual process/job handles from suspended creation through reaping."""
    def __init__(self, argv, cwd, environment, pipes, *, fresh):
        self.fresh = fresh
        self.process = None
        self.job = None
        self.pid = None
        self.returncode = None
        self.baseline = set()
        self.group = None
        if os.name == "nt":
            info = PROCESS_INFORMATION()
            startup = STARTUPINFO()
            startup.cb = ctypes.sizeof(startup)
            startup.dwFlags = 0x100
            startup.hStdInput = pipes["stdin"].child
            startup.hStdOutput = pipes["stdout"].child
            startup.hStdError = pipes["stderr"].child
            if fresh:
                token = json.loads(environment[OWNER_ENV])["token"]
                self.job = _check(_create_job(None, "Local\\GauntletTest-" + token))
                limits = EXTENDED_LIMIT()
                limits.BasicLimitInformation.LimitFlags = 0x2000  # kill on close; no breakaway
                _check(_set_job(self.job, 9, ctypes.byref(limits), ctypes.sizeof(limits)))
            else:
                token = json.loads(environment[OWNER_ENV])["token"]
                self.job = _check(_open_job(4, False, "Local\\GauntletTest-" + token))
                self.baseline = self.members()
            command = ctypes.create_unicode_buffer(subprocess.list2cmdline(argv))
            block = ctypes.create_unicode_buffer("\0".join(
                f"{key}={value}" for key, value in sorted(environment.items(), key=lambda x: x[0].upper())) + "\0\0")
            try:
                _check(_create_process(None, command, None, None, True,
                                       0x4 | 0x400 | 0x08000000, block, str(cwd),
                                       ctypes.byref(startup), ctypes.byref(info)))
                self.process, self.pid = info.hProcess, info.dwProcessId
                if fresh:
                    _check(_assign_job(self.job, self.process))
                if _resume(info.hThread) == 0xFFFFFFFF:
                    raise ctypes.WinError(ctypes.get_last_error())
            except BaseException:
                if self.process:
                    _terminate_process(self.process, 74)
                    _wait(self.process, 0)
                raise
            finally:
                if info.hThread:
                    _close(info.hThread)
        else:
            if not fresh:
                self.group = json.loads(environment[OWNER_ENV])["group"]
                self.baseline = self.members()
            self.process = subprocess.Popen(argv, cwd=cwd, env=environment,
                                            stdin=pipes["stdin"].child,
                                            stdout=pipes["stdout"].child,
                                            stderr=pipes["stderr"].child,
                                            pass_fds=tuple({pipes["control"].child,
                                                            json.loads(environment[OWNER_ENV])["control"]}),
                                            start_new_session=fresh)
            self.pid = self.process.pid
            if fresh:
                self.group = self.pid
        if not fresh:
            _NESTED_CHILDREN.add(self)

    def poll(self):
        if self.process is None:
            return None
        if self.returncode is not None:
            return self.returncode
        if os.name == "nt":
            status = _wait(self.process, 0)
            if status == 0:
                code = W.DWORD()
                _check(_exit_code(self.process, ctypes.byref(code)))
                self.returncode = code.value
            elif status != 258:
                raise ctypes.WinError(ctypes.get_last_error())
        else:
            self.returncode = self.process.poll()
        return self.returncode

    def active(self):
        if not self.fresh:
            return bool(self.owned_members())
        if os.name == "nt":
            accounting = ACCOUNTING()
            _check(_query_job(self.job, 1, ctypes.byref(accounting), ctypes.sizeof(accounting), None))
            return accounting.ActiveProcesses > 0
        try:
            os.killpg(self.pid, 0)
            return True
        except ProcessLookupError:
            return False

    def terminate(self):
        if os.name == "nt":
            _check(_terminate_job(self.job, 74) if self.fresh else
                   _terminate_process(self.process, 74))
        else:
            try:
                os.killpg(self.pid, signal.SIGKILL) if self.fresh else os.kill(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def has_descendants(self):
        members = self.members() if self.fresh else self.owned_members()
        self.inventory = {"root": self.pid, "members": sorted(members),
                          "baseline": sorted(self.baseline)}
        return bool(members - self.baseline - {self.pid})

    def owned_members(self):
        members = self.members()
        # Peers share the enclosing group/job. A later registered peer is not a
        # descendant of this one; excluding only launch-time members deadlocks
        # first-peer shutdown. Unknown/orphan members remain owned conservatively.
        siblings = {peer.pid for peer in _NESTED_CHILDREN if peer is not self}
        excluded = set(siblings)
        parents = {pid: self.parent_pid(pid) for pid in members - self.baseline}
        while True:
            expanded = excluded | {pid for pid, parent in parents.items() if parent in excluded}
            if expanded == excluded:
                break
            excluded = expanded
        return members - self.baseline - excluded

    @staticmethod
    def parent_pid(pid):
        if os.name == "nt":
            handle = _open_process(0x1000, False, pid)
            if not handle:
                if ctypes.get_last_error() == 87:  # exited between inventories
                    return None
                raise ctypes.WinError(ctypes.get_last_error())
            try:
                info, returned = PROCESS_BASIC_INFORMATION(), W.ULONG()
                status = _query_process(handle, 0, ctypes.byref(info), ctypes.sizeof(info), ctypes.byref(returned))
                if status < 0 or returned.value != ctypes.sizeof(info):
                    raise OSError(f"process ancestry query failed: {status:#x}")
                return info.InheritedFromUniqueProcessId
            finally:
                _check(_close(handle))
        if sys.platform.startswith("linux"):
            try:
                fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
                return int(fields[1])
            except FileNotFoundError:
                return None
        if sys.platform == "darwin":
            class BsdInfo(ctypes.Structure):
                _fields_ = [("prefix", ctypes.c_uint32 * 12), ("comm", ctypes.c_char * 16),
                            ("name", ctypes.c_char * 32), ("suffix", ctypes.c_uint32 * 6),
                            ("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64)]
            library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            query = library.proc_pidinfo
            query.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
            query.restype = ctypes.c_int
            info = BsdInfo()
            count = query(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
            if count == 0 and ctypes.get_errno() == 3:
                return None
            if count != ctypes.sizeof(info):
                raise OSError(ctypes.get_errno(), "process ancestry query unavailable")
            return info.prefix[4]
        raise RuntimeError("unsupported process ancestry platform")

    def members(self):
        if os.name == "posix":
            if sys.platform == "darwin":
                # Apple's libproc.h: proc_listpgrppids returns an int PID count.
                # https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.h
                library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
                enumerate_group = library.proc_listpgrppids
                enumerate_group.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
                enumerate_group.restype = ctypes.c_int
                buffer = (ctypes.c_int * 65536)()
                ctypes.set_errno(0)
                count = enumerate_group(self.group, buffer, ctypes.sizeof(buffer))
                if count < 0 or (count == 0 and ctypes.get_errno()):
                    raise OSError(ctypes.get_errno(), "process-group inventory unavailable")
                if count >= len(buffer):
                    raise RuntimeError("process-group inventory exceeds limit")
                return {pid for pid in buffer[:count] if pid > 0}
            if not sys.platform.startswith("linux"):
                raise RuntimeError("unsupported process-group inventory platform")
            members = set()
            entries = 0
            with os.scandir("/proc") as directory:
                for entry in directory:
                    entries += 1
                    if entries > 65536:
                        raise RuntimeError("process inventory exceeds test limit")
                    if not entry.name.isdecimal():
                        continue
                    try:
                        if os.getpgid(int(entry.name)) == self.group:
                            members.add(int(entry.name))
                    except ProcessLookupError:
                        pass
            return members
        capacity = 16
        while capacity <= 65536:
            buffer = ctypes.create_string_buffer(8 + capacity * ctypes.sizeof(SIZE_T))
            if _query_job(self.job, 3, buffer, len(buffer), None):
                assigned, returned = struct.unpack("<II", buffer.raw[:8])
                if assigned != returned or returned > capacity:
                    raise RuntimeError("incomplete job membership inventory")
                members = (SIZE_T * returned).from_buffer(buffer, 8)
                return set(members)
            if ctypes.get_last_error() != 234:
                raise ctypes.WinError(ctypes.get_last_error())
            capacity *= 2
        raise RuntimeError("job membership inventory exceeds test limit")

    def close(self):
        if os.name == "nt":
            if self.process:
                _check(_close(self.process))
            if self.job:
                _check(_close(self.job))
        _NESTED_CHILDREN.discard(self)


def checkpoint(name):
    context = owner_context()
    message = json.dumps({"token": context["token"], "checkpoint": name},
                         separators=(",", ":")).encode("utf-8") + b"\n"
    if len(message) > 1024:
        raise ValueError("control frame exceeds 1 KiB")
    if os.name == "nt":
        count = W.DWORD()
        _check(_write(context["control"], message, len(message), ctypes.byref(count), None))
        if count.value != len(message):
            raise OSError("partial checkpoint write")
    else:
        if os.write(context["control"], message) != len(message):
            raise OSError("partial checkpoint write")


def _save(outcome, directory, identity):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{identity}-receipt.json"
    outcome.receipt_path = path
    value = asdict(outcome)
    value["receipt_path"] = str(path)
    for channel in CHANNEL_LIMITS:
        value[channel]["prefix"] = base64.b64encode(value[channel]["prefix"]).decode("ascii")
        value[channel]["encoding"] = "base64"
    with path.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, ensure_ascii=True, separators=(",", ":"), allow_nan=False)
        stream.flush()
        os.fsync(stream.fileno())


def run_case(argv: list[str], *, cwd: Path, environment: dict[str, str],
             deadline_seconds: float, expected: ExpectedExit = ExpectedExit()) -> CommandOutcome:
    started_at = time.monotonic()
    outcome = CommandOutcome(argv=list(argv), cwd=str(cwd),
                             started_at_utc=datetime.now(timezone.utc).isoformat(),
                             expected_exit=asdict(expected))
    identity = uuid.uuid4().hex
    directory = environment.get("GAUNTLET_TEST_RECEIPTS", str(Path.cwd() / ".superpowers" / "process-receipts"))
    Path(directory).mkdir(parents=True, exist_ok=True)
    nested = bool(os.environ.get(OWNER_ENV))
    context = None
    child = None
    pipes = {}
    writer = None
    write_errors = []
    done_writing = threading.Event()
    fatal = False
    faults = environment.get("GAUNTLET_TEST_FAULT")
    control_pending = bytearray()
    checkpoints = set()

    def error(stage, exception, *, cleanup=False):
        nonlocal fatal
        item = StageError.from_exception(stage, exception)
        (outcome.cleanup_errors if cleanup else outcome.errors).append(item)
        fatal = True
        return item

    try:
        if not argv or any(not isinstance(arg, str) or "\0" in arg for arg in argv):
            raise ValueError("nonempty native argument vector required")
        if not math.isfinite(deadline_seconds) or deadline_seconds <= 0:
            raise ValueError("positive finite deadline required")
        if nested:
            context = owner_context()
            if environment.get(OWNER_ENV) != os.environ[OWNER_ENV]:
                raise RuntimeError("nested ownership context cannot be overridden")
            if environment.get("GAUNTLET_TEST_FRESH_SESSION"):
                raise RuntimeError("nested fresh-session request is forbidden")
            outcome.deadline = context["deadline"]
            execution_deadline = context["execution_deadline"]
            budget = Budget(context["budget"], context["token"], deadline=execution_deadline)
        else:
            if environment.get(OWNER_ENV):
                raise RuntimeError("controller cannot forge an inherited owner")
            outcome.deadline = started_at + deadline_seconds
            execution_deadline = outcome.deadline - min(20, deadline_seconds / 4)
            context = {"token": identity, "deadline": outcome.deadline,
                       "execution_deadline": execution_deadline,
                       "budget": str(Path(directory).resolve() / f"{identity}-budget.bin"),
                       "control": 0, "group": 0, "controller": os.getpid(),
                       "receipts": str(Path(directory).resolve())}
            budget = Budget(context["budget"], identity, deadline=execution_deadline, create=True)
        outcome.owner_token = context["token"]
        outcome.fresh_owner = not nested
        for channel in ("stdin", "stdout", "stderr", "control"):
            pipes[channel] = RawPipe(channel == "stdin")
        child_context = dict(context)
        child_context["control"] = pipes["control"].child
        child_env = dict(environment)
        child_env.pop("GAUNTLET_TEST_STDIN", None)
        child_env.pop("GAUNTLET_TEST_FAULT", None)
        child_env.pop("GAUNTLET_TEST_CLOSE_STDIN", None)
        child_env[OWNER_ENV] = json.dumps(child_context, separators=(",", ":"))
        # POSIX group is the suspended-equivalent new session's leader PID. A
        # tiny bootstrap sets its own group value before executing user code.
        if os.name == "posix" and not nested:
            child_env["GAUNTLET_TEST_BOOTSTRAP_CONTEXT"] = child_env[OWNER_ENV]
            argv = [__import__("sys").executable, str(Path(__file__).with_name("collaborative_bootstrap.py")), *argv]
        child = NativeChild.__new__(NativeChild)
        child.__init__(argv, cwd, child_env, pipes, fresh=not nested)
        outcome.started = True
        outcome.pid = child.pid
        for pipe in pipes.values():
            pipe.close_child()
        input_data = environment.get("GAUNTLET_TEST_STDIN", "").encode("utf-8")
        if len(input_data) > 1024 * 1024:
            raise ValueError("stdin exceeds 1 MiB")

        def write_input():
            try:
                offset = 0
                while offset < len(input_data):
                    if time.monotonic() >= execution_deadline:
                        raise TimeoutError("stdin deadline expired")
                    written = pipes["stdin"].write(input_data[offset:offset + CHUNK])
                    if not written:
                        raise BrokenPipeError("zero stdin progress")
                    offset += written
                outcome.stdin_delivered = True
            except BaseException as exception:
                write_errors.append(StageError.from_exception("write", exception))
            finally:
                done_writing.set()

        # Keep stdin open until root termination so descendants holding only
        # stdin are detected from membership, not hidden by an early EOF.
        writer = threading.Thread(target=write_input, daemon=True, name="owned-stdin")
        writer.start()

        def drain():
            nonlocal fatal
            progress = False
            for channel in CHANNEL_LIMITS:
                capture = getattr(outcome, channel)
                try:
                    if faults == "read" and channel == "stdout":
                        raise OSError("injected raw-pipe read failure")
                    data = pipes[channel].read()
                    if data:
                        progress = True
                        capture.observed_bytes += len(data)
                        if capture.retained_bytes + len(data) > CHANNEL_LIMITS[channel]:
                            raise CaptureOverflow(f"{channel} retention limit exceeded")
                        budget.reserve(1 if nested else 0, len(data))
                        capture.prefix += data
                        capture.retained_bytes += len(data)
                        if channel == "control":
                            control_pending.extend(data)
                            while b"\n" in control_pending:
                                frame, _, rest = control_pending.partition(b"\n")
                                control_pending[:] = rest
                                if len(frame) + 1 > 1024:
                                    raise CaptureOverflow("control frame exceeds 1 KiB")
                                message = json.loads(frame)
                                if message.get("token") != context["token"]:
                                    raise RuntimeError("control ownership token mismatch")
                                checkpoints.add(message["checkpoint"])
                            if len(control_pending) >= 1024:
                                raise CaptureOverflow("unterminated control frame exceeds 1 KiB")
                except BaseException as exception:
                    if capture.error is None:
                        capture.error = error("read", exception)
                    if isinstance(exception, CaptureOverflow):
                        outcome.overflowed = True
            return progress

        while True:
            progress = drain()
            if environment.get("GAUNTLET_TEST_CLOSE_STDIN") == "1" and done_writing.is_set():
                # Explicit raw-protocol EOF probe; normal custody tests keep the
                # pipe open so inherited-stdin descendants cannot hide.
                pipes["stdin"].close_parent()
            if write_errors:
                outcome.errors.extend(write_errors)
                write_errors.clear()
                fatal = True
            if faults == "cancel":
                raise KeyboardInterrupt("injected cancellation")
            outcome.exit_code = child.poll()
            if outcome.exit_code is not None:
                outcome.root_reaped = True
                # Membership may transiently lag exit observation on Windows.
                # Poll with the original execution deadline, never a new grace.
                if not child.active() and all(pipes[c].eof for c in CHANNEL_LIMITS):
                    break
            if fatal:
                break
            if (expected.checkpoint and expected.checkpoint not in checkpoints and
                    time.monotonic() >= min(execution_deadline, started_at + 10)):
                outcome.timed_out = True
                error("checkpoint", TimeoutError("declared checkpoint not observed within existing budget"))
                break
            if time.monotonic() >= execution_deadline:
                if outcome.root_reaped and not nested and child.has_descendants():
                    outcome.ownership_inventory = getattr(child, "inventory", None)
                    error("descendants", RuntimeError("root exited with unretired job/group members"))
                outcome.timed_out = True
                fatal = True
                break
            if not progress:
                time.sleep(min(0.005, max(0, execution_deadline - time.monotonic())))
    except KeyboardInterrupt as exception:
        outcome.cancelled = True
        error("cancellation", exception)
    except BaseException as exception:
        error("launch" if not outcome.started else "execution", exception)
    finally:
        if nested and fatal:
            for channel in CHANNEL_LIMITS:
                getattr(outcome, channel).incomplete = True
            outcome.elapsed_seconds = time.monotonic() - started_at
            _save(outcome, directory, identity)
            try:
                checkpoint("nested-fatal")
            finally:
                os._exit(74)
        if child is not None and child.pid is not None:
            outcome.started = True
            outcome.pid = child.pid
            try:
                if child.active() or fatal:
                    outcome.termination_requested = True
                    child.terminate()
                    outcome.termination_result = "requested"
                while time.monotonic() < outcome.deadline:
                    outcome.exit_code = child.poll()
                    outcome.root_reaped = outcome.exit_code is not None
                    if "drain" in locals():
                        drain()
                    retired = not child.active()
                    if outcome.root_reaped and retired:
                        outcome.tree_retired = True
                        break
                    time.sleep(min(0.005, max(0, outcome.deadline - time.monotonic())))
                if not outcome.tree_retired:
                    error("retirement", TimeoutError("tree retirement unconfirmed at owner deadline"), cleanup=True)
                # Drain EOF only after retirement; no buffered stream is closed
                # under a live reader or writer.
                while time.monotonic() < outcome.deadline and not all(
                        pipes[c].eof for c in CHANNEL_LIMITS):
                    if "drain" not in locals() or not drain():
                        time.sleep(min(0.002, max(0, outcome.deadline - time.monotonic())))
                outcome.readers_settled = all(pipes[c].eof for c in CHANNEL_LIMITS)
                if not outcome.readers_settled:
                    error("read-settlement", TimeoutError("pipe EOF unconfirmed"), cleanup=True)
            except BaseException as exception:
                error("retirement", exception, cleanup=True)
        else:
            outcome.tree_retired = True  # no process was created
            outcome.readers_settled = True
        if writer is not None:
            writer.join(max(0, outcome.deadline - time.monotonic()))
            outcome.writer_settled = not writer.is_alive()
            outcome.errors.extend(write_errors)
            if write_errors:
                fatal = True
            if not outcome.writer_settled:
                error("write-settlement", TimeoutError("stdin worker not settled"), cleanup=True)
        else:
            outcome.writer_settled = True
        for pipe in pipes.values():
            try:
                pipe.close_child()
                if outcome.writer_settled:
                    pipe.close_parent()
            except BaseException as exception:
                error("pipe-close", exception, cleanup=True)
        if child is not None:
            try:
                child.close()
            except BaseException as exception:
                error("handle-close", exception, cleanup=True)
        if faults in ("retirement", "cleanup"):
            error(faults, OSError("injected unconfirmed cleanup"), cleanup=True)
            if faults == "retirement":
                outcome.tree_retired = False
        if control_pending:
            error("control", ValueError("incomplete control frame"))
        outcome.expectation_match = (not fatal and outcome.started and
                                     outcome.exit_code == expected.exit_code and
                                     (expected.checkpoint is None or expected.checkpoint in checkpoints))
        outcome.completed = (outcome.expectation_match and outcome.root_reaped and
                             outcome.tree_retired and outcome.readers_settled and outcome.writer_settled and
                             outcome.stdin_delivered and not outcome.errors and not outcome.cleanup_errors)
        if not outcome.completed:
            outcome.expectation_match = False
            for channel in CHANNEL_LIMITS:
                getattr(outcome, channel).incomplete = True
        outcome.elapsed_seconds = time.monotonic() - started_at
        try:
            _save(outcome, directory, identity)
        except BaseException as exception:
            outcome.completed = outcome.expectation_match = False
            outcome.errors.append(StageError.from_exception("receipt", exception))
            if nested:
                try:
                    checkpoint("receipt-write-failure")
                finally:
                    os._exit(74)
            raise CommandFailure(outcome) from exception
    if not outcome.completed:
        if nested:
            # The controller observes root failure and retires the entire case.
            # Partial evidence is durable before the fatal notification/exit.
            try:
                checkpoint("nested-fatal")
            finally:
                os._exit(74)
        raise CommandFailure(outcome)
    return outcome


class OwnedTransport:
    """SDK transport inside an existing case; never creates a session or job.

    Optional imports occur only on connection. A fatal transport failure writes
    its receipt and exits the enclosing worker so its external owner retires all
    peers. Memory streams have zero queued messages (bounded backpressure).
    """
    def __init__(self, argv, *, cwd, environment=None):
        self.argv = list(argv)
        self.cwd = Path(cwd)
        self.environment = dict(os.environ) if environment is None else dict(environment)
        self.outcome = None

    async def __aenter__(self):
        self._manager = self._connect()
        return await self._manager.__aenter__()

    async def __aexit__(self, *exception):
        return await self._manager.__aexit__(*exception)

    @staticmethod
    def _context_manager(function):
        # Keep even the asynccontextmanager decoration independent of the SDK.
        from contextlib import asynccontextmanager
        return asynccontextmanager(function)

    @_context_manager
    async def _connect(self):
        import anyio
        from mcp.shared.message import SessionMessage
        from mcp_types import jsonrpc_message_adapter

        context = owner_context()
        if self.environment.get(OWNER_ENV) != os.environ[OWNER_ENV]:
            raise RuntimeError("transport cannot replace inherited custody")
        deadline = context["execution_deadline"]
        budget = Budget(context["budget"], context["token"], deadline=deadline)
        outcome = self.outcome = CommandOutcome(argv=self.argv, cwd=str(self.cwd),
                                               started_at_utc=datetime.now(timezone.utc).isoformat(),
                                               expected_exit=asdict(ExpectedExit()),
                                               deadline=context["deadline"],
                                               owner_token=context["token"], fresh_owner=False)
        identity, started_at = uuid.uuid4().hex, time.monotonic()
        pipes, child = {}, None
        closing = False
        writer_thread = None
        frame = bytearray()
        writer_done = anyio.Event()
        reader_done = anyio.Event()
        stderr_done = anyio.Event()
        stdin_bytes = 0
        read_send, read_receive = anyio.create_memory_object_stream(0)
        write_send, write_receive = anyio.create_memory_object_stream(0)

        def fail(stage, exception):
            outcome.errors.append(StageError.from_exception(stage, exception))
            outcome.overflowed |= isinstance(exception, CaptureOverflow)
            outcome.timed_out |= isinstance(exception, TimeoutError)
            outcome.cancelled |= isinstance(exception, anyio.get_cancelled_exc_class())
            for name in CHANNEL_LIMITS:
                getattr(outcome, name).incomplete = True
            if child is not None:
                outcome.exit_code = child.poll()
                outcome.root_reaped = outcome.exit_code is not None
            outcome.elapsed_seconds = time.monotonic() - started_at
            _save(outcome, context["receipts"], identity)
            try:
                checkpoint("transport-fatal")
            finally:
                # Do not turn a partially closed peer into an accepted result.
                # The retained external job/group owner kills the entire worker.
                os._exit(74)

        async def tick():
            if time.monotonic() >= deadline:
                raise TimeoutError("inherited transport execution deadline expired")
            await anyio.sleep(min(.002, max(0, deadline - time.monotonic())))

        def retain(name, data):
            capture = getattr(outcome, name)
            capture.observed_bytes += len(data)
            if capture.retained_bytes + len(data) > CHANNEL_LIMITS[name]:
                raise CaptureOverflow(f"transport {name} capture exceeds limit")
            budget.reserve(1, len(data))
            capture.prefix += data
            capture.retained_bytes += len(data)

        async def stdout_reader():
            nonlocal frame
            try:
                async with read_send:
                    while True:
                        data = pipes["stdout"].read()
                        if data == b"":
                            if frame:
                                raise ValueError("incomplete JSON-RPC frame at EOF")
                            break
                        if data is None:
                            await tick()
                            continue
                        retain("stdout", data)
                        for part_index, part in enumerate(data.split(b"\n")):
                            if part_index:
                                # A frame's size was bounded before parsing.
                                message = jsonrpc_message_adapter.validate_json(bytes(frame), by_name=False)
                                budget.reserve(1, -len(frame))
                                frame.clear()
                                if not closing:
                                    try:
                                        with anyio.fail_after(max(0, deadline - time.monotonic())):
                                            await read_send.send(SessionMessage(message))
                                    except (anyio.BrokenResourceError, anyio.ClosedResourceError):
                                        if not closing:
                                            raise
                            if len(frame) + len(part) > 512 * 1024:
                                raise CaptureOverflow("JSON-RPC frame exceeds 512 KiB before parsing")
                            budget.reserve(1, len(part))
                            frame.extend(part)
                reader_done.set()
            except BaseException as exception:
                fail("protocol", exception)

        async def stderr_reader():
            try:
                while True:
                    data = pipes["stderr"].read()
                    if data == b"":
                        break
                    if data is None:
                        await tick()
                    else:
                        retain("stderr", data)
                stderr_done.set()
            except BaseException as exception:
                fail("read", exception)

        async def stdin_writer():
            nonlocal stdin_bytes, writer_thread
            try:
                async with write_receive:
                    async for message in write_receive:
                        data = (message.message.model_dump_json(by_alias=True, exclude_unset=True) + "\n").encode("utf-8")
                        if len(data) > 512 * 1024 + 1:
                            raise CaptureOverflow("outgoing JSON-RPC frame exceeds 512 KiB")
                        stdin_bytes += len(data)
                        if stdin_bytes > 1024 * 1024:
                            raise CaptureOverflow("transport stdin exceeds 1 MiB")
                        budget.reserve(1, len(data))
                        settled, errors = threading.Event(), []

                        def write_frame():
                            try:
                                offset = 0
                                while offset < len(data):
                                    if time.monotonic() >= deadline:
                                        raise TimeoutError("inherited stdin deadline expired")
                                    count = pipes["stdin"].write(data[offset:offset + CHUNK])
                                    if count <= 0:
                                        raise BrokenPipeError("zero frame progress")
                                    offset += count
                            except BaseException as exception:
                                errors.append(exception)
                            finally:
                                settled.set()

                        writer_thread = threading.Thread(target=write_frame, daemon=True, name="owned-mcp-stdin")
                        writer_thread.start()
                        while not settled.is_set():
                            await tick()
                        writer_thread.join(max(0, deadline - time.monotonic()))
                        budget.reserve(1, -len(data))
                        if errors:
                            raise errors[0]
                outcome.stdin_delivered = True
                writer_done.set()
            except BaseException as exception:
                fail("write", exception)

        try:
            for name in ("stdin", "stdout", "stderr", "control"):
                pipes[name] = RawPipe(name == "stdin")
            child = NativeChild.__new__(NativeChild)
            child.__init__(self.argv, self.cwd, self.environment, pipes, fresh=False)
            outcome.started = True
            outcome.pid = child.pid
            for pipe in pipes.values():
                pipe.close_child()
            async with anyio.create_task_group() as group:
                group.start_soon(stdout_reader)
                group.start_soon(stderr_reader)
                group.start_soon(stdin_writer)
                try:
                    yield read_receive, write_send
                finally:
                    closing = True
                    # Teardown consumes the existing absolute execution deadline.
                    # The outer owner retains the cleanup reserve if this fails.
                    with anyio.CancelScope(shield=True, deadline=deadline):
                        await write_send.aclose()
                        await read_receive.aclose()
                        while not writer_done.is_set():
                            await tick()
                        outcome.writer_settled = writer_thread is None or not writer_thread.is_alive()
                        if not outcome.writer_settled:
                            raise RuntimeError("MCP writer failed to settle")
                        pipes["stdin"].close_parent()
                        while (child.poll() is None or child.active() or not reader_done.is_set()
                               or not stderr_done.is_set()):
                            await tick()
                        outcome.exit_code = child.poll()
                        outcome.root_reaped = True
                        outcome.tree_retired = not child.active()
                        outcome.readers_settled = True
                        if outcome.exit_code != 0 or not outcome.tree_retired:
                            raise RuntimeError("MCP peer exit/retirement incomplete")
                        group.cancel_scope.cancel()
            outcome.completed = outcome.expectation_match = True
        except BaseException as exception:
            fail("transport", exception)
        finally:
            if outcome.completed:
                for pipe in pipes.values():
                    pipe.close_child()
                    pipe.close_parent()
                child.close()
                outcome.elapsed_seconds = time.monotonic() - started_at
                _save(outcome, context["receipts"], identity)
