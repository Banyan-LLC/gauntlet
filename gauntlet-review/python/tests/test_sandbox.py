import os

import pytest

from gauntlet_review.sandbox import run_round, reap_stale, RoundResult
from gauntlet_review.runconfig import RunConfig
from gauntlet_review.lease import RunLease

# Valid generated run ids are "gauntlet-" + 32 hex; the reaper acts only on this exact shape.
DEAD = "gauntlet-" + "d" * 32
STUCK = "gauntlet-" + "c" * 32
LIVE = "gauntlet-" + "a" * 32
ORPHAN = "gauntlet-" + "b" * 32


class FakeRuntime:
    def __init__(self, *, exit_status=0, verdict=b'{"verdict":"approve"}', timed_out=False,
                 over_limit=False, start_failed=False, proc_error=None, cp_ok=True, rm_raises=False,
                 create_raises=False):
        self.calls = []
        self._exit_status = exit_status
        self._verdict = verdict
        self._timed_out = timed_out
        self._over_limit = over_limit
        self._start_failed = start_failed
        self._proc_error = proc_error
        self._cp_ok = cp_ok
        self._rm_raises = rm_raises
        self._create_raises = create_raises

    def create(self, argv):
        self.calls.append("create")
        if self._create_raises:
            raise RuntimeError("create boom")
        return "cid-1"

    def start(self, cid, stdin_bytes, timeout_sec):
        self.calls.append("start")
        from gauntlet_review.bounded import ProcResult
        return ProcResult(exit_code=(None if self._timed_out else 0), stdout=b"", stderr=b"",
                          timed_out=self._timed_out, start_failed=self._start_failed,
                          error=self._proc_error, stdout_truncated=self._over_limit,
                          stderr_truncated=False, over_limit=self._over_limit)

    def read_exit_status(self, cid):
        return self._exit_status

    def cp_out_bounded(self, cid, src, dest, max_bytes):
        self.calls.append("cp")
        if not self._cp_ok:
            return False
        with open(dest, "wb") as fh:
            fh.write(self._verdict)
        return True

    def kill(self, cid):
        self.calls.append("kill")

    def rm(self, cid):
        self.calls.append("rm")
        if self._rm_raises:
            raise RuntimeError("rm boom")


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


def _make_staging(cfg):
    os.makedirs(cfg.staging_dir, exist_ok=True)
    with open(os.path.join(cfg.staging_dir, "auth.json"), "w", encoding="utf-8") as fh:
        fh.write('{"tokens":{"access_token":"AT"}}')


def test_run_round_reclaims_staging_dir_on_success(tmp_path):
    cfg = _cfg(tmp_path)
    _make_staging(cfg)
    res = run_round(FakeRuntime(exit_status=0), cfg, prompt_bytes=b"p", timeout_sec=30,
                    marker_path=str(tmp_path / "marker"))
    assert res.verdict_path and not os.path.exists(cfg.staging_dir)  # credential reclaimed


def test_run_round_reclaims_staging_on_create_failure(tmp_path):
    cfg = _cfg(tmp_path)
    _make_staging(cfg)
    rt = FakeRuntime(create_raises=True)
    res = run_round(rt, cfg, prompt_bytes=b"p", timeout_sec=30, marker_path=str(tmp_path / "marker"))
    assert res.error and not os.path.exists(cfg.staging_dir)  # cleaned even though create() raised
    assert "rm" not in rt.calls  # no container id was ever created, so nothing to rm


def test_reaper_reclaims_staging_dir(tmp_path):
    lease_dir = tmp_path / "leases"; lease_dir.mkdir()
    staging_root = tmp_path / "staging"; staging_root.mkdir()
    (staging_root / DEAD).mkdir()
    (staging_root / DEAD / "auth.json").write_text("{}", encoding="utf-8")
    (lease_dir / f"{DEAD}.lease").write_text("", encoding="utf-8")

    class RT(FakeRuntime):
        def list_labeled(self, prefix):
            return [DEAD]
    reaped = reap_stale(RT(), lease_dir=str(lease_dir), label_prefix="gauntlet-",
                        staging_root=str(staging_root))
    assert reaped == [DEAD] and not (staging_root / DEAD).exists()


def test_fail_closed_on_start_failure(tmp_path):
    # A container that fails to start must not proceed to read a verdict from partial input.
    rt = FakeRuntime(start_failed=True)
    res = run_round(rt, _cfg(tmp_path), prompt_bytes=b"p", timeout_sec=30,
                    marker_path=str(tmp_path / "marker"))
    assert res.verdict_path is None and res.error
    assert "cp" not in rt.calls and "kill" in rt.calls and "rm" in rt.calls


def test_fail_closed_on_stdin_fault(tmp_path):
    # A stdin-delivery fault (prompt only partially delivered) must fail closed, no verdict.
    rt = FakeRuntime(proc_error="stdin write failed: EPIPE")
    res = run_round(rt, _cfg(tmp_path), prompt_bytes=b"p", timeout_sec=30,
                    marker_path=str(tmp_path / "marker"))
    assert res.verdict_path is None and "stdin write failed" in (res.error or "")
    assert "cp" not in rt.calls


def test_failed_copy_out_sets_error(tmp_path):
    rt = FakeRuntime(cp_ok=False)
    res = run_round(rt, _cfg(tmp_path), prompt_bytes=b"p", timeout_sec=30,
                    marker_path=str(tmp_path / "marker"))
    assert res.verdict_path is None and "copy-out" in (res.error or "")


def test_rm_failure_is_surfaced(tmp_path):
    rt = FakeRuntime(rm_raises=True)
    res = run_round(rt, _cfg(tmp_path), prompt_bytes=b"p", timeout_sec=30,
                    marker_path=str(tmp_path / "marker"))
    assert "container rm failed" in (res.error or "")


def test_reaper_does_not_report_run_when_rm_fails(tmp_path):
    lease_dir = tmp_path / "leases"; lease_dir.mkdir()
    staging_root = tmp_path / "staging"; staging_root.mkdir()
    (lease_dir / f"{STUCK}.lease").write_text("", encoding="utf-8")

    class RT(FakeRuntime):
        def list_labeled(self, prefix):
            return [STUCK]
    reaped = reap_stale(RT(rm_raises=True), lease_dir=str(lease_dir), label_prefix="gauntlet-",
                        staging_root=str(staging_root))
    assert reaped == []  # rm failed -> not reported reaped (container still present)
    assert (lease_dir / f"{STUCK}.lease").exists()  # lease kept for the next sweep


def test_reaper_skips_a_live_run(tmp_path):
    lease_dir = tmp_path / "leases"; lease_dir.mkdir()
    staging_root = tmp_path / "staging"; staging_root.mkdir()
    live = RunLease.acquire(str(lease_dir / f"{LIVE}.lease"))  # a live run holds its lease
    try:
        class RT(FakeRuntime):
            def list_labeled(self, prefix):
                return [LIVE]
        reaped = reap_stale(RT(), lease_dir=str(lease_dir), label_prefix="gauntlet-",
                            staging_root=str(staging_root))
        assert LIVE not in reaped  # live run must not be reaped
    finally:
        live.release()


def test_reaper_reclaims_a_dead_run(tmp_path):
    lease_dir = tmp_path / "leases"; lease_dir.mkdir()
    staging_root = tmp_path / "staging"; staging_root.mkdir()
    (lease_dir / f"{DEAD}.lease").write_text("", encoding="utf-8")  # no one holds it

    class RT(FakeRuntime):
        def list_labeled(self, prefix):
            return [DEAD]
    reaped = reap_stale(RT(), lease_dir=str(lease_dir), label_prefix="gauntlet-",
                        staging_root=str(staging_root))
    assert reaped == [DEAD]
    assert not (lease_dir / f"{DEAD}.lease").exists()  # lease removed after a confirmed reap


def test_reaper_reclaims_staging_when_no_container_exists(tmp_path):
    # Crash BETWEEN staging the credential and creating the container: a staging dir + lease
    # exist but no labeled container. The reaper must still discover and reclaim the credential.
    lease_dir = tmp_path / "leases"; lease_dir.mkdir()
    staging_root = tmp_path / "staging"; staging_root.mkdir()
    (staging_root / ORPHAN).mkdir()
    (staging_root / ORPHAN / "auth.json").write_text("{}", encoding="utf-8")
    (lease_dir / f"{ORPHAN}.lease").write_text("", encoding="utf-8")

    class RT(FakeRuntime):
        def list_labeled(self, prefix):
            return []  # NO container was ever created
    reaped = reap_stale(RT(), lease_dir=str(lease_dir), label_prefix="gauntlet-",
                        staging_root=str(staging_root))
    assert reaped == [ORPHAN]
    assert not (staging_root / ORPHAN).exists()  # credential reclaimed anyway


def test_reaper_reclaims_credentials_even_if_container_listing_fails(tmp_path):
    # A daemon outage makes list_labeled raise; the sweep must NOT abort -- an orphaned staging
    # credential (known only locally) is still reclaimed.
    lease_dir = tmp_path / "leases"; lease_dir.mkdir()
    staging_root = tmp_path / "staging"; staging_root.mkdir()
    (staging_root / ORPHAN).mkdir()
    (staging_root / ORPHAN / "auth.json").write_text("{}", encoding="utf-8")
    (lease_dir / f"{ORPHAN}.lease").write_text("", encoding="utf-8")

    class RT(FakeRuntime):
        def list_labeled(self, prefix):
            raise RuntimeError("docker daemon unreachable")
    reaped = reap_stale(RT(), lease_dir=str(lease_dir), label_prefix="gauntlet-",
                        staging_root=str(staging_root))
    assert reaped == [ORPHAN] and not (staging_root / ORPHAN).exists()


def test_reaper_ignores_unrelated_entries(tmp_path):
    # A non-run-id entry under staging_root / lease_dir must never be leased or deleted.
    lease_dir = tmp_path / "leases"; lease_dir.mkdir()
    staging_root = tmp_path / "staging"; staging_root.mkdir()
    unrelated = staging_root / "important-data"
    unrelated.mkdir()
    (unrelated / "keep.txt").write_text("do not delete", encoding="utf-8")
    (lease_dir / "notes.txt").write_text("x", encoding="utf-8")

    class RT(FakeRuntime):
        def list_labeled(self, prefix):
            return []
    reaped = reap_stale(RT(), lease_dir=str(lease_dir), label_prefix="gauntlet-",
                        staging_root=str(staging_root))
    assert reaped == []
    assert unrelated.exists() and (unrelated / "keep.txt").exists()  # untouched


def test_reaper_does_not_report_when_staging_cleanup_fails(tmp_path, monkeypatch):
    # A forced staging-cleanup failure must NOT be reported as a successful reap (a live token
    # could remain on disk); the run is left for the next sweep.
    import gauntlet_review.sandbox as sb
    lease_dir = tmp_path / "leases"; lease_dir.mkdir()
    staging_root = tmp_path / "staging"; staging_root.mkdir()
    (staging_root / DEAD).mkdir()
    (lease_dir / f"{DEAD}.lease").write_text("", encoding="utf-8")
    monkeypatch.setattr(sb, "discard_staging", lambda p: "residual: auth.json still present")

    class RT(FakeRuntime):
        def list_labeled(self, prefix):
            return [DEAD]
    reaped = reap_stale(RT(), lease_dir=str(lease_dir), label_prefix="gauntlet-",
                        staging_root=str(staging_root))
    assert reaped == []  # staging residual -> not reaped
    assert (lease_dir / f"{DEAD}.lease").exists()  # lease kept for retry
