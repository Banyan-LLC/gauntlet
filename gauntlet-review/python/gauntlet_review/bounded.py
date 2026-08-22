"""Bounded subprocess runner. Python analogue of Invoke-BoundedProcess (lib.ps1):
async stdin, concurrently-drained stdout/stderr under per-channel AND aggregate byte caps
(bounding RETAINED bytes, not just a threshold), ONE shared deadline, IMMEDIATE process-tree
termination the moment a cap is crossed OR a stdin fault is seen (spec: "explicit per-channel
and aggregate byte bounds ... immediate ... termination if a limit is exceeded"), guaranteed
detection of incomplete prompt delivery, bounded cleanup, and NEVER raise for process failure.

Production note: the container-sandbox path that drives this runner runs on Unix/macOS (Windows
uses the PowerShell stack). POSIX process-group termination is therefore the production path and
is robust even after the direct child exits; Windows termination is best-effort via taskkill."""
from __future__ import annotations

import os
import signal
import subprocess
import threading
import time
from dataclasses import dataclass

# All post-kill reaping (process wait + thread joins) is bounded by ONE documented grace, so
# total wall-clock cannot run far past the shared deadline.
_CLEANUP_GRACE_SEC = 10
_POLL_SEC = 0.1


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


def _drain(stream, cap: int, out: dict, key: str, lock, agg: dict, max_total: int, overflow):
    # Read to EOF so the child never blocks on a full pipe, but bound BOTH the per-channel and
    # the combined RETAINED bytes: reserve aggregate space under the lock before appending, so
    # len(stdout)+len(stderr) can never exceed max_total. Crossing any cap sets `overflow`,
    # which the coordinator turns into an immediate tree-kill; we keep reading-and-discarding
    # afterwards so the child cannot wedge on a full pipe before the kill lands.
    buf = bytearray()
    truncated = False
    while True:
        try:
            # read1(): return whatever is available in ONE underlying read (>=1 byte, or b"" at
            # EOF) instead of blocking for a full 64 KB buffer -- this is what makes cap
            # detection immediate for a child that writes a little then holds the pipe open.
            chunk = stream.read1(65536)
        except (OSError, ValueError):
            # Best-effort: the main thread may close this pipe out from under us while we're
            # still blocked reading from an already-timed-out/killed child. Exit quietly.
            break
        if not chunk:
            break
        n = len(chunk)
        with lock:
            agg["observed"] += n
            room = max(0, min(cap - len(buf), max_total - agg["retained"]))
            agg["retained"] += room
            agg_over = agg["observed"] > max_total
        if room:
            buf += chunk[:room]
        if n > room:
            truncated = True
        if truncated or agg_over:
            overflow.set()
    out[key] = bytes(buf)
    out[key + "_truncated"] = truncated


def _make_killer(proc):
    """Return a callable that terminates the whole process TREE. On POSIX the group id is
    captured now so the group can be killed even after the direct child exits (a descendant
    that inherited the pipes keeps the group alive). On Windows termination is best-effort."""
    pgid = None
    if os.name == "posix":
        try:
            pgid = os.getpgid(proc.pid)
        except OSError:
            pgid = None

    def kill():
        try:
            if os.name == "posix":
                os.killpg(pgid if pgid is not None else os.getpgid(proc.pid), signal.SIGKILL)
                return
            # Windows: kill the whole tree by PID; leaves a descendant that outlives the direct
            # child un-reaped (documented non-production limitation -- Windows uses the PS stack).
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
                    proc.kill()
                except (ProcessLookupError, PermissionError, OSError):
                    pass

    return kill


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
        popen_kwargs["start_new_session"] = True  # own process group, for group/tree kill
    try:
        proc = subprocess.Popen(argv, **popen_kwargs)
    except OSError as exc:
        return ProcResult(None, b"", b"", False, True, str(exc), False, False)

    kill = _make_killer(proc)
    deadline = time.monotonic() + timeout_sec

    def remaining():
        return max(0, deadline - time.monotonic())

    captured: dict = {}
    lock = threading.Lock()
    agg = {"observed": 0, "retained": 0}   # bytes seen / bytes retained, across both channels
    overflow = threading.Event()           # set the instant any per-channel or aggregate cap is crossed
    t_out = threading.Thread(target=_drain,
                             args=(proc.stdout, max_stdout, captured, "stdout", lock, agg, max_total, overflow),
                             daemon=True)
    t_err = threading.Thread(target=_drain,
                             args=(proc.stderr, max_stderr, captured, "stderr", lock, agg, max_total, overflow),
                             daemon=True)
    t_out.start()
    t_err.start()

    write_state: dict = {}   # "ok": full write+flush delivered; "exc": delivery faulted (incomplete)

    def _write():
        try:
            if stdin_bytes:
                proc.stdin.write(stdin_bytes)
                proc.stdin.flush()   # force bytes to the pipe so "ok" means genuinely delivered
            write_state["ok"] = True
        except (BrokenPipeError, OSError) as exc:  # incomplete delivery (child read a prefix / stdin closed)
            write_state["exc"] = exc
            return
        try:
            proc.stdin.close()
        except (BrokenPipeError, OSError):
            pass  # close failing AFTER a complete write is benign

    t_in = threading.Thread(target=_write, daemon=True)
    t_in.start()

    timed_out = False
    error: str | None = None

    # Unified event loop: concurrently observe overflow, a stdin fault while the child is still
    # alive, the shared deadline, and process exit -- so a child that floods a stream while
    # refusing stdin is killed the instant it overflows, not only after the deadline.
    while True:
        if overflow.is_set():
            kill()
            break
        if "exc" in write_state and proc.poll() is None:
            # stdin delivery faulted while the child is still running: a genuine fault.
            error = f"stdin write failed: {write_state['exc']}"
            kill()
            break
        if remaining() <= 0:
            timed_out = True
            kill()
            break
        try:
            proc.wait(timeout=_POLL_SEC)
            break  # exited on its own
        except subprocess.TimeoutExpired:
            continue

    # Bounded cleanup. Give the drains a brief chance for a clean EOF; if they are still blocked
    # a descendant inherited the pipes, so tree-kill to release them (covers the normal-exit
    # path too), then bound the reap AND remaining joins by ONE grace.
    cleanup_deadline = time.monotonic() + _CLEANUP_GRACE_SEC
    t_out.join(timeout=0.2)
    t_err.join(timeout=0.2)
    if t_out.is_alive() or t_err.is_alive():
        kill()
    if proc.poll() is None:
        try:
            proc.wait(timeout=max(0, cleanup_deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            pass
    for t in (t_in, t_out, t_err):
        t.join(timeout=max(0, cleanup_deadline - time.monotonic()))

    # Close only streams whose thread has settled -- NEVER close a BufferedReader/Writer that a
    # daemon thread may still be reading/writing (that call can block behind the outstanding I/O).
    if not t_in.is_alive():
        _safe_close(proc.stdin)
    if not t_out.is_alive():
        _safe_close(proc.stdout)
    if not t_err.is_alive():
        _safe_close(proc.stderr)

    over_limit = overflow.is_set()
    # Incomplete prompt delivery must fail closed regardless of child exit state: a child that
    # consumed only a prefix (EPIPE on flush) would otherwise yield a verdict from partial input.
    if error is None and not timed_out and not over_limit and stdin_bytes and not write_state.get("ok"):
        error = f"stdin write failed: incomplete delivery ({write_state.get('exc', 'partial write')})"

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


def _safe_close(stream):
    try:
        stream.close()
    except OSError:
        pass
