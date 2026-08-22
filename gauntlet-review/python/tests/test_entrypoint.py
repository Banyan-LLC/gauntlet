import importlib.util
import sys
import time
from pathlib import Path

# Load the entrypoint module by path (it lives outside the package).
_SPEC = importlib.util.spec_from_file_location(
    "gauntlet_entrypoint",
    str(Path(__file__).resolve().parents[2] / "docker" / "entrypoint.py"),
)
entry = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(entry)


class FakeProc:
    """Fake process handle exposing the Popen-like surface run() depends on."""

    def __init__(self, exit_code):
        self._exit_code = exit_code
        self.killed = False
        self.kill_calls = 0

    def poll(self):
        return self._exit_code

    def kill(self):
        self.killed = True
        self.kill_calls += 1

    def wait(self, timeout=None):
        return self._exit_code


class NeverExitsProc:
    """Fake process that never exits on its own; records whether kill() was called."""

    def __init__(self):
        self.killed = False
        self.kill_calls = 0
        self._exit_code = None

    def poll(self):
        return None

    def kill(self):
        self.killed = True
        self.kill_calls += 1
        # Once killed, simulate the OS reaping it so wait() can return.
        self._exit_code = -9

    def wait(self, timeout=None):
        return self._exit_code


def test_records_exit_status_and_waits_for_marker(tmp_path):
    exit_path = tmp_path / "exit-status"
    marker = tmp_path / "marker"

    def fake_spawn(argv, stdin_fd):
        return FakeProc(3)  # simulate codex exiting 3, already done when polled

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
    fake_proc = NeverExitsProc()

    def slow_spawn(argv, stdin_fd):
        # Simulate a child that would run forever; entrypoint's watchdog must kill it.
        return fake_proc

    with_marker = tmp_path / "marker"
    with_marker.write_text("go", encoding="utf-8")

    started = time.monotonic()
    rc = entry.run(codex_argv=["codex"], verdict_path=str(tmp_path / "v.json"),
                   exit_status_path=str(tmp_path / "e"), marker_path=str(with_marker),
                   deadline_sec=0, spawn=slow_spawn, poll_interval=0.01)
    elapsed = time.monotonic() - started

    assert fake_proc.killed  # the watchdog must actually kill the overrunning child
    assert rc != 0  # a watchdog-fired run is a non-zero result
    assert elapsed < 3  # must not block forever waiting on the fake proc


def test_watchdog_kills_real_subprocess(tmp_path):
    # Exercise the real spawn path: a genuine subprocess that sleeps far longer than the
    # watchdog deadline must actually be killed, proving the real (non-fake) kill path fires.
    marker = tmp_path / "marker"
    marker.write_text("go", encoding="utf-8")

    started = time.monotonic()
    rc = entry.run(
        codex_argv=[sys.executable, "-c", "import time; time.sleep(30)"],
        verdict_path=str(tmp_path / "v.json"),
        exit_status_path=str(tmp_path / "e"),
        marker_path=str(marker),
        deadline_sec=1,
        spawn=entry._default_spawn,
        poll_interval=0.05,
    )
    elapsed = time.monotonic() - started

    assert elapsed < 10  # well under the 30s sleep -> proves the child was actually killed
    assert rc != 0
