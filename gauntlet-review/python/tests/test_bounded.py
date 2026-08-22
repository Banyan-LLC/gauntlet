import sys
import time

from gauntlet_review.bounded import run_bounded

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
