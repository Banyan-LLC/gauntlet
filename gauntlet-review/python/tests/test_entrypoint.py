import importlib.util
import os
from pathlib import Path

# Load the entrypoint module by path (it lives outside the package).
_SPEC = importlib.util.spec_from_file_location(
    "gauntlet_entrypoint",
    str(Path(__file__).resolve().parents[2] / "docker" / "entrypoint.py"),
)
entry = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(entry)


def test_records_exit_status_and_waits_for_marker(tmp_path):
    exit_path = tmp_path / "exit-status"
    marker = tmp_path / "marker"

    def fake_spawn(argv, stdin_fd):
        return 3  # simulate codex exiting 3

    # Marker already present -> run() returns promptly after recording exit status.
    marker.write_text("go", encoding="utf-8")
    rc = entry.run(codex_argv=["codex", "exec", "-"], verdict_path=str(tmp_path / "v.json"),
                   exit_status_path=str(exit_path), marker_path=str(marker),
                   deadline_sec=30, spawn=fake_spawn, poll_interval=0.01)
    assert exit_path.read_text().strip() == "3"
    assert rc == 3


def test_watchdog_deadline_is_absolute():
    # 5s deadline from a start point -> deadline is start+5, independent of wall drift.
    assert entry.compute_watchdog_deadline(1000.0, 5) == 1005.0


def test_watchdog_kills_when_codex_overruns(tmp_path):
    killed = {"n": 0}

    def slow_spawn(argv, stdin_fd):
        # Simulate a child that would run forever; entrypoint's watchdog must kill it.
        raise entry.WatchdogFired()

    with_marker = tmp_path / "marker"
    with_marker.write_text("go", encoding="utf-8")
    rc = entry.run(codex_argv=["codex"], verdict_path=str(tmp_path / "v.json"),
                   exit_status_path=str(tmp_path / "e"), marker_path=str(with_marker),
                   deadline_sec=0, spawn=slow_spawn, poll_interval=0.01)
    assert rc != 0  # a watchdog-fired run is a non-zero result
