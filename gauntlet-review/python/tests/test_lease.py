from gauntlet_review.lease import new_run_id, RunLease


def test_run_id_unguessable_and_unique():
    a, b = new_run_id(), new_run_id()
    assert a != b and a.startswith("gauntlet-") and len(a) > 20


def test_lease_is_exclusive_non_blocking(tmp_path):
    p = tmp_path / "run.lease"
    held = RunLease.acquire(str(p))
    try:
        assert RunLease.try_acquire(str(p)) is None  # a second acquirer must fail non-blockingly
    finally:
        held.release()


def test_lease_reacquirable_after_release(tmp_path):
    p = tmp_path / "run.lease"
    RunLease.acquire(str(p)).release()
    second = RunLease.try_acquire(str(p))
    assert second is not None
    second.release()


def test_lease_context_manager_releases(tmp_path):
    p = tmp_path / "run.lease"
    with RunLease.acquire(str(p)):
        assert RunLease.try_acquire(str(p)) is None
    assert RunLease.try_acquire(str(p)) is not None
