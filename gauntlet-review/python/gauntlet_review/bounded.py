"""Bounded subprocess runner. Python analogue of Invoke-BoundedProcess (lib.ps1):
async stdin, concurrently-drained stdout/stderr under byte caps, one shared deadline,
kill the process group on timeout, and NEVER raise for process-level failure."""
from __future__ import annotations

import os
import signal
import subprocess
import threading
import time
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
        try:
            chunk = stream.read(65536)
        except (OSError, ValueError):
            # Best-effort: the main thread may close this pipe out from under us
            # while we're still blocked reading from an already-timed-out/killed
            # child. Exit quietly instead of surfacing via threading.excepthook.
            break
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

    deadline = time.monotonic() + timeout_sec

    def remaining():
        return max(0, deadline - time.monotonic())

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
        except (BrokenPipeError, OSError) as exc:  # broken pipe: child exited, or a genuine fault
            write_err["e"] = exc

    t_in = threading.Thread(target=_write, daemon=True)
    t_in.start()

    timed_out = False
    error: str | None = None

    t_in.join(timeout=remaining())
    if t_in.is_alive():
        # Write did not complete within the deadline: a child that never drains stdin.
        timed_out = True
        _kill(proc)
    elif "e" in write_err and proc.poll() is None:
        # Write failed while the child is still running: a genuine fault, not a
        # benign failure caused by an already-exited child. Surface it and kill early.
        error = f"stdin write failed: {write_err['e']}"
        _kill(proc)
    else:
        # stdin delivered, or the write failed only because the child already
        # exited (benign): proceed to collect its exit.
        try:
            proc.wait(timeout=remaining())
        except subprocess.TimeoutExpired:
            timed_out = True
            _kill(proc)

    # Single generic reap for every kill path above (timeout, stalled-stdin
    # write, or fault-while-alive): avoids a redundant double-wait.
    if (timed_out or error is not None) and proc.poll() is None:
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass

    t_in.join(timeout=5)
    t_out.join(timeout=15)
    t_err.join(timeout=15)

    # A write failure raised before reaching `proc.stdin.close()` inside `_write()`
    # (e.g. a genuine fault, or the kill-while-blocked path) leaves the stdin pipe
    # open; closing here is idempotent and guarantees no unclosed-file warnings.
    try:
        proc.stdin.close()
    except OSError:
        pass
    try:
        proc.stdout.close()
    except OSError:
        pass
    try:
        proc.stderr.close()
    except OSError:
        pass

    return ProcResult(
        exit_code=(None if (timed_out or error is not None) else proc.returncode),
        stdout=captured.get("stdout", b""),
        stderr=captured.get("stderr", b""),
        timed_out=timed_out,
        start_failed=False,
        error=error,
        stdout_truncated=captured.get("stdout_truncated", False),
        stderr_truncated=captured.get("stderr_truncated", False),
    )
