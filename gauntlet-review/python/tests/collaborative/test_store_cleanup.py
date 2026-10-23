"""Real SQLite operations with injected cleanup faults at the storage boundary."""
import asyncio
import sqlite3

import pytest

from gauntlet_review.collaborative.contracts import CoreError


def fault_connections(monkeypatch, *, rollback=None, close=None, inspect=None, writes_only=False):
    connect=sqlite3.connect
    observed=[]

    class FaultConnection(sqlite3.Connection):
        def __init__(self,*args,**kwargs):
            super().__init__(*args,**kwargs)
            self.writing=False
            self.close_calls=0
            self.rollback_calls=0
            observed.append(self)

        @property
        def in_transaction(self):
            if inspect is not None:
                raise inspect
            return sqlite3.Connection.in_transaction.__get__(self)

        def execute(self,statement,*args,**kwargs):
            if statement=='BEGIN IMMEDIATE':
                self.writing=True
            if statement=='ROLLBACK':
                self.rollback_calls+=1
                if rollback is not None:
                    raise rollback
            return super().execute(statement,*args,**kwargs)

        def close(self):
            self.close_calls+=1
            super().close()
            if close is not None and (not writes_only or self.writing):
                raise close

    def faulty(*args,**kwargs):
        return connect(*args,**kwargs,factory=FaultConnection)

    monkeypatch.setattr(sqlite3,'connect',faulty)
    return observed


def causes(error):
    found=[]
    def walk(value):
        if value is None or any(value is old for old in found):
            return
        found.append(value)
        walk(value.__cause__)
        for child in getattr(value,'exceptions',()):
            walk(child)
    walk(error)
    return found


@pytest.mark.parametrize('primary,code,retryable',[
    (CoreError('CONFLICT',True,{'reason':'original_conflict'}),'CONFLICT',True),
    (sqlite3.OperationalError('database is locked'),'LOCK_TIMEOUT',True),
    (sqlite3.DatabaseError('invalid database'),'CORRUPT_STATE',False),
])
def test_primary_storage_failure_and_both_cleanup_causes_survive(store,monkeypatch,primary,code,retryable):
    rollback=sqlite3.OperationalError('injected rollback failure')
    close=sqlite3.OperationalError('injected close failure')
    with monkeypatch.context() as patch:
        observed=fault_connections(patch,rollback=rollback,close=close)
        with pytest.raises(CoreError) as caught:
            with store._connection() as connection:
                connection.execute('BEGIN IMMEDIATE')
                raise primary
    assert caught.value.code==code and caught.value.retryable is retryable
    assert caught.value.detail['cleanup_failed'] is True
    assert all(any(item is error for item in causes(caught.value)) for error in (primary,rollback,close))
    assert len(observed)==1 and observed[0].rollback_calls==observed[0].close_calls==1
    assert store.version()==0


def test_failed_transaction_observation_still_closes_and_returns_typed_uncertainty(store,monkeypatch):
    failure=OSError('injected transaction observation failure')
    with monkeypatch.context() as patch:
        observed=fault_connections(patch,inspect=failure)
        with pytest.raises(CoreError) as caught:
            with store._connection():
                pass
    assert caught.value.code=='STORAGE_ERROR' and caught.value.retryable
    assert caught.value.detail['reason']=='storage_outcome_uncertain'
    assert any(error is failure for error in causes(caught.value))
    assert observed[0].close_calls==1 and store.version()==0


def test_real_caller_cancellation_survives_rollback_and_close_failures(store,monkeypatch):
    cancellation=asyncio.CancelledError('caller cancellation')
    rollback=sqlite3.OperationalError('injected rollback failure')
    close=sqlite3.OperationalError('injected close failure')
    with monkeypatch.context() as patch:
        observed=fault_connections(patch,rollback=rollback,close=close)
        with pytest.raises(asyncio.CancelledError) as caught:
            with store._connection() as connection:
                connection.execute('BEGIN IMMEDIATE')
                raise cancellation
    assert caught.value is cancellation
    assert all(any(item is error for item in causes(caught.value)) for error in (rollback,close))
    assert observed[0].rollback_calls==observed[0].close_calls==1 and store.version()==0


@pytest.mark.anyio
async def test_post_commit_close_failure_reports_uncertainty_and_exact_retry_recovers(flow,monkeypatch):
    request={'key':'post_commit_close','expected_version':0}
    failure=sqlite3.OperationalError('injected close after durable commit')
    with monkeypatch.context() as patch:
        observed=fault_connections(patch,close=failure,writes_only=True)
        response=await flow.author.open_review(request)
    assert response['ok'] is False and response['error']['code']=='STORAGE_ERROR',response
    assert response['error']['retryable'] is True
    assert response['error']['detail']['reason']=='storage_outcome_uncertain'
    assert response['freshness']=={'state':'unknown'}
    assert any(connection.writing and connection.close_calls==1 for connection in observed)
    history=flow.author.store.read_series()
    recovered=await flow.author.open_review(request)
    assert recovered['ok'] and recovered['freshness']=={'state':'not_checked'}
    assert recovered['result']['event_id']==history.events[0].id
    assert flow.author.store.version()==1 and len(flow.author.store.read_series().events)==1


@pytest.mark.anyio
@pytest.mark.parametrize('operation',['review_status','read_review'])
async def test_read_close_failure_remains_a_typed_storage_result(flow,monkeypatch,operation):
    opened=await flow.open()
    request={} if operation=='review_status' else {**flow.bound(opened),'view':'manifest'}
    with monkeypatch.context() as patch:
        fault_connections(patch,close=sqlite3.OperationalError('injected read close failure'))
        response=await getattr(flow.author,operation)(request)
    assert response['ok'] is False and response['error']['code']=='STORAGE_ERROR',response
    assert response['error']['retryable'] is True
    assert response['error']['detail']['reason']=='storage_outcome_uncertain'
    assert flow.author.store.version()==1


@pytest.mark.parametrize('ambient',[CoreError('CONFLICT',True),asyncio.CancelledError('already handled')])
def test_successful_read_cleanup_does_not_inherit_a_callers_handled_exception(store,monkeypatch,ambient):
    try:
        raise ambient
    except BaseException:
        with monkeypatch.context() as patch:
            fault_connections(patch,close=sqlite3.OperationalError('injected read close failure'))
            with pytest.raises(CoreError) as caught:
                with store._connection(read=True) as connection:
                    assert connection.execute('SELECT 1').fetchone()[0]==1
    assert caught.value.code=='STORAGE_ERROR' and caught.value.retryable
    assert caught.value.detail['reason']=='storage_outcome_uncertain'
    assert not any(error is ambient for error in causes(caught.value))


@pytest.mark.anyio
@pytest.mark.parametrize('ambient',[CoreError('CONFLICT',True),asyncio.CancelledError('already handled')])
async def test_post_commit_cleanup_does_not_inherit_a_callers_handled_exception(flow,monkeypatch,ambient):
    request={'key':'ambient_post_commit','expected_version':0}
    try:
        raise ambient
    except BaseException:
        with monkeypatch.context() as patch:
            fault_connections(patch,close=sqlite3.OperationalError('injected post-commit close'),writes_only=True)
            try:
                response=await flow.author.open_review(request)
            except BaseException as error:
                response=error
    assert isinstance(response,dict),response
    assert not response['ok'] and response['error']['code']=='STORAGE_ERROR',response
    assert response['error']['detail']['reason']=='storage_outcome_uncertain'
    recovered=await flow.author.open_review(request)
    assert recovered['ok'] and recovered['freshness']=={'state':'not_checked'}
    assert flow.author.store.version()==1 and len(flow.author.store.read_series().events)==1


@pytest.mark.parametrize('kind',['schema','corrupt','cancel'])
@pytest.mark.parametrize('cleanup',['rollback','inspection'])
def test_startup_preserves_primary_and_all_cleanup_failures(store,monkeypatch,kind,cleanup):
    from gauntlet_review.collaborative.store import Store
    primary=(asyncio.CancelledError('startup cancellation') if kind=='cancel' else
             CoreError('UNSUPPORTED_SCHEMA' if kind=='schema' else 'CORRUPT_STATE'))
    failure=sqlite3.OperationalError('injected startup rollback failure') if cleanup=='rollback' else OSError('injected transaction inspection failure')
    close=sqlite3.OperationalError('injected startup close failure')
    def reject(connection):
        raise primary
    with monkeypatch.context() as patch:
        observed=fault_connections(patch,close=close,**{('rollback' if cleanup=='rollback' else 'inspect'):failure})
        patch.setattr(Store,'_schema',staticmethod(reject))
        with pytest.raises(type(primary)) as caught:
            Store.open(store.config,store.repo_binding)
    if isinstance(primary,CoreError):
        assert caught.value.code==primary.code and caught.value.detail['cleanup_failed'] is True
    else:
        assert caught.value is primary
    assert all(any(item is error for item in causes(caught.value)) for error in (primary,failure,close))
    assert observed[0].close_calls==1
    assert observed[0].rollback_calls==(1 if cleanup=='rollback' else 0)
    assert store.version()==0
