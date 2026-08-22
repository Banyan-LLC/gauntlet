"""Bounded subprocess runner. Python analogue of Invoke-BoundedProcess (lib.ps1):
async stdin, concurrently-drained stdout/stderr under per-channel AND aggregate byte caps,
one shared deadline, IMMEDIATE process(-group/-tree) termination the moment a cap is exceeded
(spec: "explicit per-channel and aggregate byte bounds ... immediate ... termination if a
limit is exceeded, so a long or malformed run cannot exhaust host memory or disk"), and
NEVER raise for process-level failure."""
from __future__ import annotations

import os
import signal
import subprocess
import threading
import time
from dataclasses import dataclass

# All post-kill reaping (process wait + thread joins) is bounded by ONE documented grace, so
# total wall-clock cannot run far past the shared deadline. Prior code could add ~45s of
# unbounded waits/joins beyond the deadline; this caps the whole cleanup window.
_CLEANUP_GRACE_SEC = 10


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
    over_limit: bool = False  # a per-channel OR aggregate byte cap was exceeded -> run terminated


def _drain(stream, cap: int, out: dict, key: str, lock, agg: list, max_total: int, overflow):
    # Read to EOF so the child never blocks on a full pipe, but retain only `cap` bytes and
    # count the aggregate across BOTH channels. Crossing either the per-channel cap or the
    # aggregate cap sets `overflow`, which the coordinator turns into an immediate kill; we
    # keep reading-and-discarding afterwards so the child cannot wedge on a full pipe before
    # the kill lands, while retained memory stays bounded by `cap`.
    buf = bytearray()
    truncated = False
    while True:
        try:
            # read1(): return whatever is available in ONE underlying read (>=1 byte, or b""
            # at EOF) instead of blocking for a full 64 KB buffer. This is what makes cap
            # detection immediate for a child that writes a little and then holds the pipe open.
            chunk = stream.read1(65536)
        except (OSError, ValueError):
            # Best-effort: the main thread may close this pipe out from under us while we're
            # still blocked reading from an already-timed-out/killed child. Exit quietly.
            break
        if not chunk:
            break
        n = len(chunk)
        if len(buf) < cap:
            room = cap - len(buf)
            buf += chunk[:room]
            if n > room:
                truncated = True
        else:
            truncated = True
        with lock:
            agg[0] += n
            agg_over = agg[0] > max_total
        if truncated or agg_over:
            overflow.set()
    out[key] = bytes(buf)
    out[key + "_truncated"] = truncated


def _kill(proc):
    try:
        if os.name == "posix":
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            return
        # Windows: kill the whole process TREE. proc.kill() alone terminates only the direct
        # child, leaving grandchildren (e.g. a container-attach helper) holding the pipes.
        subprocess.run(
            ["taskkill", "/F", "/T", "/PID", str(proc.pid)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except (ProcessLookupError, PermissionError, OSError):
        pass
    finally:
        if os.name != "posix":
            try:
                proc.kill()  # fallback if taskkill is unavailable on this host
            except (ProcessLookupError, PermissionError, OSError):
                pass


def run_bounded(argv, *, stdin_bytes=b"", timeout_sec=1800, env=None, clear_env=False,
                cwd=None, max_stdout=8_000_000, max_stderr=1_000_000,
                max_total=9_000_000) -> ProcResult:
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
    lock = threading.Lock()
    agg = [0]                       # aggregate bytes seen across both channels
    overflow = threading.Event()    # set the instant any per-channel or aggregate cap is crossed
    t_out = threading.Thread(target=_drain,
                             args=(proc.stdout, max_stdout, captured, "stdout", lock, agg, max_total, overflow),
                             daemon=True)
    t_err = threading.Thread(target=_drain,
                             args=(proc.stderr, max_stderr, captured, "stderr", lock, agg, max_total, overflow),
                             daemon=True)
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
        # Write failed while the child is still running: a genuine fault, not a benign
        # failure caused by an already-exited child. Surface it and kill early.
        error = f"stdin write failed: {write_err['e']}"
        _kill(proc)
    else:
        # stdin delivered (or the write failed only because the child already exited): wait for
        # exit, but terminate IMMEDIATELY if a stream cap is crossed, and honor the deadline.
        while True:
            if overflow.is_set():
                _kill(proc)
                break
            try:
                proc.wait(timeout=0.1)
                break
            except subprocess.TimeoutExpired:
                if remaining() <= 0:
                    timed_out = True
                    _kill(proc)
                    break

    # Single bounded cleanup window for every kill path (timeout, stalled-stdin write,
    # fault-while-alive, or over-limit): one documented grace covers the reap AND the joins.
    cleanup_deadline = time.monotonic() + _CLEANUP_GRACE_SEC
    if (timed_out or error is not None or overflow.is_set()) and proc.poll() is None:
        try:
            proc.wait(timeout=max(0, cleanup_deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            pass
    for t in (t_in, t_out, t_err):
        t.join(timeout=max(0, cleanup_deadline - time.monotonic()))

    # A write failure raised before `proc.stdin.close()` inside `_write()` leaves the stdin
    # pipe open; closing here is idempotent and guarantees no unclosed-file warnings.
    for stream in (proc.stdin, proc.stdout, proc.stderr):
        try:
            stream.close()
        except OSError:
            pass

    over_limit = overflow.is_set()
    return ProcResult(
        exit_code=(None if (timed_out or error is not None or over_limit) else proc.returncode),
        stdout=captured.get("stdout", b""),
        stderr=captured.get("stderr", b""),
        timed_out=timed_out,
        start_failed=False,
        error=error,
        stdout_truncated=captured.get("stdout_truncated", False),
        stderr_truncated=captured.get("stderr_truncated", False),
        over_limit=over_limit,
    )
