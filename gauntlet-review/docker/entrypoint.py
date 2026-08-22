"""In-container entrypoint wrapper. Runs Codex, records its exit status to the tmpfs,
then blocks on a marker so the tmpfs verdict survives host-side copy-out. An absolute
in-container watchdog kills Codex after the deadline, independent of the host — so a
runner crash cannot leave the container running forever."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time


def compute_watchdog_deadline(start_monotonic: float, deadline_sec: float) -> float:
    return start_monotonic + deadline_sec


def _default_spawn(argv, stdin_fd):
    # Non-blocking: start the child and return the handle immediately. run() owns the
    # active deadline and polls/kills it — it must never block on an unbounded wait().
    return subprocess.Popen(argv, stdin=stdin_fd)


def _stdin_fd():
    # Under a real container invocation stdin has a real fd. Under test harnesses
    # (e.g. pytest's captured stdin) fileno() is unsupported; fall back to None since
    # fake spawns used in tests don't dereference it.
    try:
        return sys.stdin.fileno()
    except (AttributeError, OSError, ValueError):
        return None


def run(*, codex_argv, verdict_path, exit_status_path, marker_path, deadline_sec,
        spawn=_default_spawn, poll_interval=0.5) -> int:
    start = time.monotonic()
    deadline = compute_watchdog_deadline(start, deadline_sec)

    proc = spawn(codex_argv, _stdin_fd())

    # Actively enforce the absolute deadline: poll for exit rather than blocking on an
    # unbounded wait(), so a hung Codex is killed even if the host itself has crashed.
    while True:
        rc = proc.poll()
        if rc is not None:
            break
        if time.monotonic() >= deadline:
            proc.kill()
            try:
                proc.wait(timeout=10)
            except Exception:
                pass
            rc = 124  # timeout convention -- the watchdog fired
            break
        time.sleep(poll_interval)

    # Record exit status for the host to read alongside the verdict.
    with open(exit_status_path, "w", encoding="utf-8") as fh:
        fh.write(str(rc))

    # Block until the host signals it has copied the verdict out (or the deadline passes).
    # Bounded wait: reuse the same absolute deadline so this loop can never block forever.
    while not os.path.exists(marker_path):
        if time.monotonic() >= deadline:
            break
        time.sleep(poll_interval)
    return rc


if __name__ == "__main__":  # pragma: no cover - exercised by the Task 9 integration test
    run(
        codex_argv=json.loads(os.environ["GAUNTLET_CODEX_ARGV_JSON"]),
        verdict_path=os.environ["GAUNTLET_VERDICT_PATH"],
        exit_status_path=os.environ["GAUNTLET_EXIT_STATUS_PATH"],
        marker_path=os.environ["GAUNTLET_MARKER_PATH"],
        deadline_sec=float(os.environ["GAUNTLET_DEADLINE_SEC"]),
    )
