"""In-container entrypoint wrapper. Runs Codex, records its exit status to the tmpfs,
then blocks on a marker so the tmpfs verdict survives host-side copy-out. An absolute
in-container watchdog kills Codex after the deadline, independent of the host — so a
runner crash cannot leave the container running forever."""
from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time


class WatchdogFired(Exception):
    pass


def compute_watchdog_deadline(start_monotonic: float, deadline_sec: float) -> float:
    return start_monotonic + deadline_sec


def _default_spawn(argv, stdin_fd) -> int:
    proc = subprocess.Popen(argv, stdin=stdin_fd)
    return proc.wait()


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
    rc = 0
    try:
        if deadline_sec <= 0 and time.monotonic() >= deadline:
            raise WatchdogFired()
        rc = spawn(codex_argv, _stdin_fd())
    except WatchdogFired:
        rc = 124  # timeout convention
    # Record exit status for the host to read alongside the verdict.
    with open(exit_status_path, "w", encoding="utf-8") as fh:
        fh.write(str(rc))
    # Block until the host signals it has copied the verdict out (or the deadline passes).
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
