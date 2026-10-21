import sqlite3

import pytest

from gauntlet_review.collaborative.contracts import CoreError


@pytest.mark.anyio
@pytest.mark.parametrize("failure_point",[1,2,3])
async def test_observed_cancellation_checkpoints_leave_no_event(store,append_event,failure_point):
    import anyio
    counter=0
    async def checkpoint():
        nonlocal counter
        counter+=1
        if counter == failure_point:
            raise anyio.get_cancelled_exc_class()()
    with pytest.raises(anyio.get_cancelled_exc_class()):
        await append_event(store,checkpoint=checkpoint)
    assert store.version() == 0 and store.read_series() is None
    with sqlite3.connect(store.path) as connection:
        assert connection.execute("SELECT COUNT(*) FROM retries").fetchone()[0] == 0


@pytest.mark.anyio
async def test_lost_response_after_commit_is_recovered_exactly_once(store,append_event,monkeypatch):
    original=store._commit
    def lost(connection):
        original(connection)
        raise OSError("simulated lost response after COMMIT")
    monkeypatch.setattr(store,"_commit",lost)
    with pytest.raises(CoreError) as error:
        await append_event(store)
    assert error.value.code == "STORAGE_ERROR"
    monkeypatch.setattr(store,"_commit",original)
    recovered=await append_event(store)
    assert recovered.replayed and store.version() == 1
    assert len(store.read_series().events) == 1


@pytest.mark.anyio
async def test_evidence_quota_rolls_back_metadata_bytes_receipt_and_version(store,append_event):
    from dataclasses import replace
    from gauntlet_review.collaborative.store import Store
    with Store.open(store.config,store.repo_binding,policy=replace(store.policy,evidence_series_bytes=3)) as limited:
        await append_event(limited)
        with pytest.raises(CoreError) as error:
            await append_event(limited,key="proof",expected_version=1,operation="record_evidence",body=b"four")
        assert error.value.code == "LIMIT_EXCEEDED"
        assert limited.version() == 1 and len(limited.read_series().events) == 1
        with sqlite3.connect(limited.path) as connection:
            assert connection.execute("SELECT COUNT(*) FROM evidence").fetchone()[0] == 0
            assert connection.execute("SELECT COUNT(*) FROM retries").fetchone()[0] == 1


@pytest.mark.anyio
@pytest.mark.parametrize("field",["series_payload_bytes","store_payload_bytes"])
async def test_payload_quota_reservation_is_atomic_and_preserves_prior_history(store,append_event,field):
    from dataclasses import replace
    from gauntlet_review.collaborative.store import Store
    with Store.open(store.config,store.repo_binding,policy=replace(store.policy,**{field:5000})) as limited:
        first=await append_event(limited)
        before=limited.read_view()
        with pytest.raises(CoreError) as error:
            await append_event(limited,key="large",expected_version=1,operation="record_evidence",body=b"x"*4096)
        assert error.value.code == "LIMIT_EXCEEDED"
        after=limited.read_view()
        assert after == before
        recovered=await append_event(limited)
        assert recovered.event_id == first.event_id and recovered.replayed


@pytest.mark.anyio
async def test_database_lock_is_a_bounded_retryable_failure(store,append_event):
    import time
    with sqlite3.connect(store.path,isolation_level=None) as blocker:
        blocker.execute("BEGIN IMMEDIATE")
        started=time.monotonic()
        try:
            with pytest.raises(CoreError) as error:
                await append_event(store)
            assert error.value.code == "LOCK_TIMEOUT" and error.value.retryable
            assert time.monotonic()-started < 3
        finally:
            blocker.execute("ROLLBACK")
    assert store.version() == 0 and store.read_series() is None


@pytest.mark.anyio
@pytest.mark.parametrize("statement",["INSERT INTO series","INSERT INTO events","INSERT INTO evidence",
                                       "INSERT INTO retries","UPDATE meta"])
async def test_io_failure_after_each_insertion_preserves_pretransaction_state(store,append_event,monkeypatch,statement):
    real_connect=sqlite3.connect
    if statement!="INSERT INTO series":
        await append_event(store)
    before=store.read_view()
    class FaultConnection:
        def __init__(self,*args,**kwargs):
            object.__setattr__(self,"connection",real_connect(*args,**kwargs))
        def __getattr__(self,name):
            return getattr(self.connection,name)
        def __setattr__(self,name,value):
            setattr(self.connection,name,value)
        def execute(self,sql,*args):
            result=self.connection.execute(sql,*args)
            if sql.startswith(statement):
                raise OSError("injected I/O failure after real SQL mutation")
            return result
    monkeypatch.setattr(sqlite3,"connect",FaultConnection)
    with pytest.raises(CoreError) as error:
        if statement=="INSERT INTO series":
            await append_event(store)
        else:
            await append_event(store,key="proof",expected_version=1,operation="record_evidence",body=b"proof")
    assert error.value.code == "STORAGE_ERROR"
    assert store.read_view() == before
