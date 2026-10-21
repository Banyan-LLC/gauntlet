"""Failures found by implementation review, exercised through public boundaries."""
import errno
import hashlib
import json
from pathlib import Path
import sqlite3

import pytest

from gauntlet_review.collaborative.contracts import CoreError,Policy,encode
from gauntlet_review.collaborative.source import GitSource
from gauntlet_review.collaborative.store import Store


@pytest.mark.anyio
@pytest.mark.parametrize("corruption",["digest","shape","semantics","producer"])
@pytest.mark.parametrize("operation",["reopen","status","unrelated_write"])
async def test_corrupt_unrelated_receipt_refuses_every_common_state_path(flow,corruption,operation):
    await flow.open()
    await flow.submit()
    evidence=await flow.evidence_request()
    assert (await flow.reviewer.review_status({}))["result"]["status"]=="peer_complete"
    path=flow.author.store.path
    with sqlite3.connect(path) as connection:
        row=connection.execute("SELECT result_bytes FROM retries WHERE operation='submit_review'").fetchone()
        raw=row[0]
        if corruption=="producer":
            connection.execute("UPDATE retries SET participant='xxxx' WHERE operation='submit_review'")
        else:
            value=json.loads(raw)
            if corruption=="semantics":
                value["result"]["accepted_round"]=2
            else:
                value["result"]["accepted"]=None
            changed=encode(value)
            assert len(changed)==len(raw)
            if corruption=="digest":
                connection.execute("UPDATE retries SET result_bytes=? WHERE operation='submit_review'",(changed,))
            else:
                connection.execute("UPDATE retries SET result_bytes=?,result_sha256=? WHERE operation='submit_review'",
                                   (changed,hashlib.sha256(changed).hexdigest()))
        before=connection.execute("SELECT store_version,payload_bytes FROM meta").fetchone()
        event_count=connection.execute("SELECT count(*) FROM events").fetchone()[0]
    if operation=="reopen":
        with pytest.raises(CoreError) as caught:
            Store.open(flow.config,flow.author.source.repo_binding)
        assert caught.value.code in ("DIGEST_MISMATCH","CORRUPT_STATE")
    else:
        response=(await flow.reviewer.review_status({}) if operation=="status" else
                  await flow.author.record_evidence(evidence))
        assert not response["ok"] and response["error"]["code"] in ("DIGEST_MISMATCH","CORRUPT_STATE"),response
        assert response["result"] is None
    with sqlite3.connect(path) as connection:
        assert connection.execute("SELECT store_version,payload_bytes FROM meta").fetchone()==before
        assert connection.execute("SELECT count(*) FROM events").fetchone()[0]==event_count


@pytest.mark.parametrize("probe",["shallow","objects/pack"])
@pytest.mark.parametrize("error_number",[errno.EACCES,errno.EIO])
def test_repository_support_probe_io_error_is_never_absence(cfg,git_fixture,monkeypatch,probe,error_number):
    git_fixture.pair({}, {b"file":(0o100644,b"one")})
    failing=cfg.repo_path/".git"/probe
    original=Path.stat
    def broken(path,*args,**kwargs):
        if path==failing:
            raise OSError(error_number,"support probe I/O failure")
        return original(path,*args,**kwargs)
    monkeypatch.setattr(Path,"stat",broken)
    with pytest.raises(CoreError) as caught:
        with GitSource(cfg) as source:
            source.capture(Policy())
    assert caught.value.code=="STORAGE_ERROR"


@pytest.mark.parametrize("application_id",[0,0x474D4331])
@pytest.mark.parametrize("version",[1,999])
def test_existing_table_free_database_version_is_not_reset(cfg,application_id,version):
    path=cfg.state_dir/Store.FILENAME
    with sqlite3.connect(path) as connection:
        connection.execute(f"PRAGMA application_id={application_id}")
        connection.execute(f"PRAGMA user_version={version}")
    with pytest.raises(CoreError) as caught:
        Store.open(cfg,str(cfg.repo_path/".git"))
    assert caught.value.code=="UNSUPPORTED_SCHEMA"
    with sqlite3.connect(path) as connection:
        assert connection.execute("PRAGMA user_version").fetchone()[0]==version
        assert connection.execute("SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()[0]==0


@pytest.mark.anyio
@pytest.mark.parametrize("side",["source","target"])
@pytest.mark.parametrize("phase",["admission","precommit","capture"])
async def test_known_ref_drift_keeps_stale_oids_and_time_without_commit(flow,monkeypatch,side,phase):
    await flow.open()
    request=await flow.evidence_request()
    def move():
        parent=flow.writer.repo.refs[flow.config.source_ref].decode()
        oid=(flow.writer.commit({b"file":(0o100644,b"moved")},parents=[parent]) if side=="source" else parent)
        flow.writer.set_ref(flow.config.source_ref if side=="source" else flow.config.target_ref,oid)
    if phase=="admission":
        move()
    elif phase=="precommit":
        count=0
        async def checkpoint():
            nonlocal count
            count+=1
            if count==3:
                move()
        monkeypatch.setattr(flow.author,"_checkpoint",checkpoint)
    else:
        original=flow.author.source._build
        def build(*args):
            snapshot=original(*args)
            move()
            return snapshot
        monkeypatch.setattr(flow.author.source,"_build",build)
    response=(await flow.author.open_review({"key":"moving-capture","expected_version":1}) if phase=="capture" else
              await flow.author.record_evidence(request))
    assert not response["ok"] and response["error"]["code"]=="STALE",response
    assert response["freshness"]["state"]=="stale",response
    assert response["freshness"]["source_oid"]==flow.writer.repo.refs[flow.config.source_ref].decode()
    assert response["freshness"]["target_oid"]==flow.writer.repo.refs[flow.config.target_ref].decode()
    assert response["freshness"]["checked_at"]
    assert flow.author.store.version()==1 and len(flow.author.store.read_series().events)==1
