import pytest

from gauntlet_review.sandbox import run_round, reap_stale, RoundResult
from gauntlet_review.runconfig import RunConfig
from gauntlet_review.lease import RunLease


class FakeRuntime:
    def __init__(self, *, exit_status=0, verdict=b'{"verdict":"approve"}', timed_out=False, over_limit=False):
        self.calls = []
        self._exit_status = exit_status
        self._verdict = verdict
        self._timed_out = timed_out
        self._over_limit = over_limit

    def create(self, argv):
        self.calls.append("create")
        return "cid-1"

    def start(self, cid, stdin_bytes, timeout_sec):
        self.calls.append("start")
        from gauntlet_review.bounded import ProcResult
        return ProcResult(exit_code=(None if self._timed_out else 0), stdout=b"", stderr=b"",
                          timed_out=self._timed_out, start_failed=False, error=None,
                          stdout_truncated=self._over_limit, stderr_truncated=False)

    def read_exit_status(self, cid):
        return self._exit_status

    def cp_out_bounded(self, cid, src, dest, max_bytes):
        self.calls.append("cp")
        with open(dest, "wb") as fh:
            fh.write(self._verdict)
        return True

    def kill(self, cid):
        self.calls.append("kill")

    def rm(self, cid):
        self.calls.append("rm")


def _cfg(tmp_path):
    return RunConfig(image_ref="img@sha256:x", platform="linux/amd64", uid=1000, gid=1000,
                     cidfile=str(tmp_path / "cid"), staging_dir=str(tmp_path / "stg"),
                     codex_home="/codex-home", tmpfs_dir="/work",
                     verdict_path="/work/verdict.json", schema_path="/codex-home/v.schema.json",
                     disable_set=["apps"], run_label="gauntlet-run-x")


def test_happy_path_retrieves_verdict_and_cleans_up(tmp_path):
    rt = FakeRuntime(exit_status=0)
    res = run_round(rt, _cfg(tmp_path), prompt_bytes=b"prompt", timeout_sec=30,
                    marker_path=str(tmp_path / "marker"))
    assert res.verdict_path and open(res.verdict_path, "rb").read() == b'{"verdict":"approve"}'
    assert res.exit_status == 0 and not res.error
    assert "rm" in rt.calls  # guaranteed cleanup

def test_cleanup_runs_even_on_timeout(tmp_path):
    rt = FakeRuntime(timed_out=True)
    res = run_round(rt, _cfg(tmp_path), prompt_bytes=b"p", timeout_sec=1,
                    marker_path=str(tmp_path / "marker"))
    assert res.timed_out and "kill" in rt.calls and "rm" in rt.calls


def test_over_limit_stream_terminates_and_flags(tmp_path):
    rt = FakeRuntime(over_limit=True)
    res = run_round(rt, _cfg(tmp_path), prompt_bytes=b"p", timeout_sec=30,
                    marker_path=str(tmp_path / "marker"))
    assert res.over_limit and "kill" in rt.calls and "rm" in rt.calls


def test_reaper_skips_a_live_run(tmp_path):
    lease_dir = tmp_path / "leases"
    lease_dir.mkdir()
    live = RunLease.acquire(str(lease_dir / "gauntlet-live.lease"))  # a live run holds its lease
    try:
        class RT(FakeRuntime):
            def list_labeled(self, prefix):
                return ["gauntlet-live"]
        reaped = reap_stale(RT(), lease_dir=str(lease_dir), label_prefix="gauntlet-")
        assert "gauntlet-live" not in reaped  # live run must not be reaped
    finally:
        live.release()


def test_reaper_reclaims_a_dead_run(tmp_path):
    lease_dir = tmp_path / "leases"
    lease_dir.mkdir()
    (lease_dir / "gauntlet-dead.lease").write_text("", encoding="utf-8")  # no one holds it

    class RT(FakeRuntime):
        def list_labeled(self, prefix):
            return ["gauntlet-dead"]
    reaped = reap_stale(RT(), lease_dir=str(lease_dir), label_prefix="gauntlet-")
    assert reaped == ["gauntlet-dead"]
