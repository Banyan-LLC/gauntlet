import os
import sys
import time

import pytest

from gauntlet_review.bounded import run_bounded, _CLEANUP_GRACE_SEC

PY = sys.executable


def test_captures_stdout_and_exit_code():
    r = run_bounded([PY, "-c", "print('hi')"], timeout_sec=30)
    assert r.exit_code == 0 and not r.timed_out and not r.start_failed
    assert r.stdout.strip() == b"hi"


def test_stdin_is_delivered():
    r = run_bounded([PY, "-c", "import sys; sys.stdout.write(sys.stdin.read())"],
                    stdin_bytes=b"payload", timeout_sec=30)
    assert r.stdout == b"payload"


def test_nonzero_exit_is_reported_not_raised():
    r = run_bounded([PY, "-c", "import sys; sys.exit(7)"], timeout_sec=30)
    assert r.exit_code == 7 and not r.timed_out


def test_start_failure_is_reported_not_raised():
    r = run_bounded(["this-binary-does-not-exist-xyz"], timeout_sec=30)
    assert r.start_failed and r.exit_code is None and r.error


def test_timeout_kills_and_flags():
    start = time.monotonic()
    r = run_bounded([PY, "-c", "import time; time.sleep(60)"], timeout_sec=1)
    assert r.timed_out and (time.monotonic() - start) < 30


def test_stdout_is_bounded_and_flagged():
    # Emit ~1 MB but cap at 1 KB: retained bytes are capped, truncation flagged, no hang.
    r = run_bounded([PY, "-c", "import sys; sys.stdout.write('a'*1_000_000)"],
                    timeout_sec=30, max_stdout=1024)
    assert r.stdout_truncated and len(r.stdout) <= 1024


def test_over_limit_terminates_immediately_not_at_timeout():
    # Child floods stdout past the cap, then sleeps well beyond the deadline. The runner must
    # kill it the moment the cap is crossed -- not wait out the sleep or the timeout.
    start = time.monotonic()
    r = run_bounded([PY, "-c", "import sys,time; sys.stdout.write('a'*200000); sys.stdout.flush(); time.sleep(30)"],
                    timeout_sec=10, max_stdout=1024)
    elapsed = time.monotonic() - start
    assert r.over_limit and r.stdout_truncated and len(r.stdout) <= 1024
    assert not r.timed_out and elapsed < 9  # terminated on overflow, not by the 10s deadline


def test_aggregate_cap_terminates_when_per_channel_caps_not_hit():
    # Neither per-channel cap is exceeded, but the combined total crosses the aggregate cap.
    r = run_bounded([PY, "-c", "import sys,time; sys.stdout.write('a'*2000); sys.stdout.flush(); time.sleep(30)"],
                    timeout_sec=10, max_stdout=100000, max_stderr=100000, max_total=1000)
    assert r.over_limit and not r.timed_out
    assert len(r.stdout) + len(r.stderr) <= 1000  # RETAINED bytes bounded by the aggregate cap


def test_many_small_writes_below_caps_are_not_over_limit():
    # A normal streaming process that emits many small chunks whose combined size stays under every
    # cap must NOT be falsely marked over-limit (regression: aggregate reservation once ignored the
    # per-chunk size and reserved a whole channel cap on the first small read).
    r = run_bounded([PY, "-c",
                     "import sys,time\n"
                     "for _ in range(50):\n"
                     "    sys.stdout.write('x'*10); sys.stdout.flush(); time.sleep(0.001)\n"],
                    timeout_sec=30, max_stdout=100000, max_stderr=100000, max_total=100000)
    assert not r.over_limit and not r.timed_out and r.exit_code == 0
    assert r.stdout == b"x" * 500


def test_incomplete_stdin_delivery_is_surfaced_even_if_child_exits_ok():
    # Child reads only a small prefix, emits a "verdict", exits 0; we send a large prompt whose
    # remaining bytes then fault (EPIPE). Incomplete delivery MUST be surfaced regardless of the
    # child's clean exit, so a verdict from partial input can be rejected downstream.
    r = run_bounded([PY, "-c", "import sys; sys.stdin.buffer.read(10); sys.stdout.write('verdict'); sys.exit(0)"],
                    stdin_bytes=b"x" * 5_000_000, timeout_sec=30)
    assert r.error and "stdin write failed" in r.error


def test_overflow_terminates_during_stalled_stdin_not_at_deadline():
    # Child never reads stdin but floods stdout while we try to send a large prompt (so the
    # writer is blocked). Overflow must be observed CONCURRENTLY and kill immediately, rather
    # than waiting out the deadline.
    start = time.monotonic()
    r = run_bounded([PY, "-c", "import sys,time; sys.stdout.write('a'*300000); sys.stdout.flush(); time.sleep(30)"],
                    stdin_bytes=b"x" * 5_000_000, timeout_sec=15, max_stdout=1024)
    elapsed = time.monotonic() - start
    assert r.over_limit and elapsed < 12  # killed on overflow, well before the 15s deadline


@pytest.mark.skipif(os.name != "posix",
                    reason="descendant process-group kill is the POSIX production path; Windows is best-effort")
def test_descendant_inheriting_pipes_is_terminated(tmp_path):
    # A grandchild inherits stdout and outlives the parent, which exits. The drain would block on
    # the grandchild's still-open pipe; run_bounded must tree-kill the group so the grandchild is
    # terminated (never writes its sentinel) AND run_bounded must not hang.
    sentinel = tmp_path / "alive.txt"
    parent = (
        "import subprocess,sys,time\n"
        f"subprocess.Popen([sys.executable,'-c','import time; time.sleep(6); open(r\"{sentinel}\",\"w\").write(\"x\")'])\n"
        "time.sleep(0.5)\n"   # give run_bounded time to capture the process group
        "sys.exit(0)\n"
    )
    start = time.monotonic()
    run_bounded([PY, "-c", parent], timeout_sec=30)
    assert (time.monotonic() - start) < _CLEANUP_GRACE_SEC + 5  # bounded; did not hang
    time.sleep(7)  # past the grandchild's 6s sleep
    assert not sentinel.exists()  # the descendant was terminated by the tree-kill


@pytest.mark.skipif(os.name != "posix",
                    reason="descendant process-group kill is the POSIX production path; Windows is best-effort")
def test_descendant_inheriting_only_stdin_is_terminated(tmp_path):
    # A descendant inherits ONLY stdin (redirecting its own stdout/stderr away) and outlives the
    # parent. The stdout/stderr drains reach EOF, but the stdin writer stays blocked -> the
    # liveness check must include the writer so the group is still tree-killed.
    sentinel = tmp_path / "alive_stdin.txt"
    parent = (
        "import subprocess,sys,time\n"
        "subprocess.Popen([sys.executable,'-c','import time; time.sleep(6); "
        f"open(r\"{sentinel}\",\"w\").write(\"x\")'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
        "time.sleep(0.5)\n"   # give run_bounded time to capture the process group
        "sys.exit(0)\n"       # parent exits WITHOUT reading our large stdin
    )
    start = time.monotonic()
    run_bounded([PY, "-c", parent], stdin_bytes=b"y" * 5_000_000, timeout_sec=30)
    assert (time.monotonic() - start) < _CLEANUP_GRACE_SEC + 5  # bounded; did not hang
    time.sleep(7)
    assert not sentinel.exists()  # descendant holding only stdin was still reaped


def test_huge_stdin_does_not_deadlock_against_slow_reader():
    # Child reads a little then exits; we still must not block writing a large stdin.
    r = run_bounded([PY, "-c", "import sys; sys.stdin.read(10); print('ok')"],
                    stdin_bytes=b"x" * 5_000_000, timeout_sec=30)
    assert r.stdout.strip() == b"ok"


def test_error_surfaced_when_child_stops_reading_stdin_while_alive():
    # Child reads a few bytes, then sleeps for a long time WITHOUT exiting and
    # WITHOUT closing stdin: the write blocks on a full pipe against a child
    # that is genuinely still alive. This must be detected within the timeout
    # (fast-fail with an error), not silently waited out to the full sleep.
    start = time.monotonic()
    r = run_bounded(
        [PY, "-c", "import sys, time; sys.stdin.read(5); time.sleep(30)"],
        stdin_bytes=b"x" * 5_000_000,
        timeout_sec=2,
    )
    elapsed = time.monotonic() - start
    assert elapsed < 30
    assert r.timed_out or r.error


@pytest.mark.skipif(os.name != "posix", reason="broken-pipe-while-alive is only reliably reproducible on POSIX EPIPE semantics")
def test_error_surfaced_on_write_failure_while_child_alive():
    # Child closes its stdin read end but stays alive; a large write then hits EPIPE
    # while the process is still running -> fast-fail with error, not a full-timeout wait.
    r = run_bounded([PY, "-c", "import sys,time; sys.stdin.close(); time.sleep(30)"],
                    stdin_bytes=b"x" * 5_000_000, timeout_sec=5)
    assert r.error and "stdin write failed" in r.error
    assert not r.timed_out  # it was a detected fault, not a timeout
