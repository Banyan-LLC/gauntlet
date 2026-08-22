"""Bounded subprocess runner. Python analogue of Invoke-BoundedProcess (lib.ps1):
async stdin, concurrently-drained stdout/stderr under byte caps, one shared deadline,
kill the process group on timeout, and NEVER raise for process-level failure."""
from __future__ import annotations

import os
import signal
import subprocess
import threading
from dataclasses import dataclass


@dataclass
class ProcResult:
    exit_code: int | None
    stdout: bytes
    stderr: bytes
    timed_out: bool
    start_failed: bool
    error: str | None
    stdout_truncated: bool
    stderr_truncated: bool


def _drain(stream, cap: int, out: dict, key: str):
    # Read to EOF so the child never blocks on a full pipe, but retain only `cap` bytes.
    buf = bytearray()
    truncated = False
    while True:
        chunk = stream.read(65536)
        if not chunk:
            break
        if len(buf) < cap:
            room = cap - len(buf)
            buf += chunk[:room]
            if len(chunk) > room:
                truncated = True
        else:
            truncated = True
    out[key] = bytes(buf)
    out[key + "_truncated"] = truncated


def _kill(proc):
    try:
        if os.name == "posix":
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        else:
            proc.kill()
    except (ProcessLookupError, PermissionError, OSError):
        pass


def run_bounded(argv, *, stdin_bytes=b"", timeout_sec=1800, env=None, clear_env=False,
                cwd=None, max_stdout=8_000_000, max_stderr=1_000_000) -> ProcResult:
    full_env = ({} if clear_env else dict(os.environ))
    if env:
        full_env.update(env)
    popen_kwargs = dict(
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        cwd=cwd, env=full_env,
    )
    if os.name == "posix":
        popen_kwargs["start_new_session"] = True  # own process group, for group-kill
    try:
        proc = subprocess.Popen(argv, **popen_kwargs)
    except OSError as exc:
        return ProcResult(None, b"", b"", False, True, str(exc), False, False)

    captured: dict = {}
    t_out = threading.Thread(target=_drain, args=(proc.stdout, max_stdout, captured, "stdout"), daemon=True)
    t_err = threading.Thread(target=_drain, args=(proc.stderr, max_stderr, captured, "stderr"), daemon=True)
    t_out.start()
    t_err.start()

    write_err = {}

    def _write():
        try:
            if stdin_bytes:
                proc.stdin.write(stdin_bytes)
            proc.stdin.close()
        except (BrokenPipeError, OSError) as exc:  # child exited without draining: normal failure
            write_err["e"] = exc

    t_in = threading.Thread(target=_write, daemon=True)
    t_in.start()

    timed_out = False
    try:
        proc.wait(timeout=timeout_sec)
    except subprocess.TimeoutExpired:
        timed_out = True
        _kill(proc)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass

    t_in.join(timeout=5)
    t_out.join(timeout=15)
    t_err.join(timeout=15)

    return ProcResult(
        exit_code=(None if timed_out else proc.returncode),
        stdout=captured.get("stdout", b""),
        stderr=captured.get("stderr", b""),
        timed_out=timed_out,
        start_failed=False,
        error=None,
        stdout_truncated=captured.get("stdout_truncated", False),
        stderr_truncated=captured.get("stderr_truncated", False),
    )
