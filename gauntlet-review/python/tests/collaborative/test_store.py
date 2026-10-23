from dataclasses import replace
import hashlib
import json
import os
from pathlib import Path
import sqlite3

import pytest

from gauntlet_review.collaborative.contracts import CoreError,Policy


@pytest.mark.anyio
async def test_exact_retry_precedes_stale_version(store,append_event):
    first=await append_event(store)
    again=await append_event(store,build_hook=lambda _:pytest.fail("retry rebuilt source"))
    assert first.event_id == again.event_id and first.result_bytes == again.result_bytes
    assert again.replayed and not first.replayed
    assert store.version() == 1 and len(store.read_series().events) == 1


@pytest.mark.anyio
async def test_changed_key_content_and_stale_new_key_conflict(store,append_event):
    await append_event(store)
    for key,version in (("once",1),("other",0)):
        with pytest.raises(CoreError) as error:
            await append_event(store,key=key,expected_version=version)
        assert error.value.code == "CONFLICT" and error.value.retryable
    assert store.version() == 1


@pytest.mark.anyio
async def test_reopen_existing_regular_database_and_recover_result(store,append_event):
    from gauntlet_review.collaborative.store import Store
    first=await append_event(store)
    with Store.open(store.config,store.repo_binding) as reopened:
        result=await append_event(reopened)
        assert result.replayed and result.result_bytes == first.result_bytes
        assert reopened.read_series().id == store.read_series().id


@pytest.mark.anyio
async def test_two_connections_compare_and_swap_exactly_one_winner(store,append_event):
    import anyio
    from gauntlet_review.collaborative.store import Store
    outcomes=[]
    async def submit(connection,key):
        try:
            outcomes.append(await append_event(connection,key=key))
        except CoreError as error:
            outcomes.append(error.code)
    with Store.open(store.config,store.repo_binding) as second:
        async with anyio.create_task_group() as group:
            group.start_soon(submit,store,"first")
            group.start_soon(submit,second,"second")
    assert sum(isinstance(item,str) and item == "CONFLICT" for item in outcomes) == 1
    assert len(store.read_series().events) == store.version() == 1


@pytest.mark.anyio
async def test_identical_keys_in_two_series_do_not_alias(store,append_event):
    from gauntlet_review.collaborative.store import Store
    first=await append_event(store)
    other=replace(store.config,repository_id="second")
    with Store.open(other,store.repo_binding) as second:
        initial=await append_event(second,expected_version=1)
        repeated=await append_event(second,expected_version=1)
        assert initial.event_id == repeated.event_id != first.event_id
        assert second.read_series().id != store.read_series().id
        assert second.version() == 2


@pytest.mark.anyio
async def test_participant_operation_and_role_bind_retries(store,append_event):
    from gauntlet_review.collaborative.store import Store
    first=await append_event(store)
    evidence=await append_event(store,expected_version=1,operation="record_evidence",body=b"proof")
    assert evidence.event_id != first.event_id
    with Store.open(replace(store.config,participant="other"),store.repo_binding) as other:
        new=await append_event(other,expected_version=2)
        assert new.event_id != first.event_id
    with Store.open(replace(store.config,role="reviewer"),store.repo_binding) as changed_role:
        with pytest.raises(CoreError) as error:
            await append_event(changed_role)
        assert error.value.code == "CONFLICT"


@pytest.mark.anyio
async def test_persisted_repository_and_policy_checked_before_direct_retry(store,append_event,monkeypatch,tmp_path):
    await append_event(store)
    config=store.config
    fingerprint="0"*64
    for field,value in (("repo_binding",str(tmp_path/"different-git")),
                        ("policy",replace(Policy(),findings=201))):
        with monkeypatch.context() as patch:
            patch.setattr(store,field,value)
            with pytest.raises(CoreError) as error:
                store.lookup_retry(config.series_scope,config.participant,"open_review","once",fingerprint)
            assert error.value.code == "CONFIGURATION_MISMATCH"
            with pytest.raises(CoreError) as error:
                await append_event(store)
            assert error.value.code == "CONFIGURATION_MISMATCH"


@pytest.mark.anyio
async def test_different_common_directory_cannot_open_same_series(store,append_event,tmp_path):
    from dulwich.repo import Repo
    from gauntlet_review.collaborative.store import Store
    await append_event(store)
    other=tmp_path/"other-repo"
    other.mkdir()
    Repo.init(str(other)).close()
    with pytest.raises(CoreError) as error:
        Store.open(replace(store.config,repo_path=other),os.path.normcase(str((other/".git").resolve())))
    assert error.value.code == "CONFIGURATION_MISMATCH"


@pytest.mark.anyio
async def test_event_and_evidence_whole_digest_checked_before_any_page(store,append_event):
    await append_event(store)
    result=await append_event(store,key="proof",expected_version=1,operation="record_evidence",body=b"abcd")
    history=store.read_series()
    page=store.read_page(history.id,history.current_revision,"history",None,100)
    assert len(page.items) == 2 and page.complete
    descriptor=next(row for row in page.items if row["id"] == result.event_id)
    data=store.read_artifact(history.id,history.current_revision,descriptor["artifact_id"],0,65536)
    assert data.data == history.events[-1].body and data.eof
    with sqlite3.connect(store.path) as corrupt:
        corrupt.execute("UPDATE evidence SET bytes=?",(b"abce",))
    with pytest.raises(CoreError) as error:
        store.read_series()
    assert error.value.code == "DIGEST_MISMATCH"


@pytest.mark.anyio
async def test_receipt_digest_and_semantic_version_bindings_are_checked(store,append_event):
    await append_event(store)
    with sqlite3.connect(store.path) as corrupt:
        row=corrupt.execute("SELECT result_bytes FROM retries").fetchone()
        result=json.loads(row[0])
        result["store_version"]=2
        from gauntlet_review.collaborative.contracts import encode
        changed=encode(result)
        corrupt.execute("UPDATE retries SET result_bytes=?,result_sha256=?",
                        (changed,hashlib.sha256(changed).hexdigest()))
    with pytest.raises(CoreError) as error:
        await append_event(store)
    assert error.value.code == "CORRUPT_STATE"


@pytest.mark.anyio
async def test_event_raw_corruption_is_not_empty_history(store,append_event):
    await append_event(store)
    with sqlite3.connect(store.path) as corrupt:
        corrupt.execute("UPDATE events SET body=?",(b"{}",))
    with pytest.raises(CoreError) as error:
        store.read_series()
    assert error.value.code == "DIGEST_MISMATCH"


def test_invalid_relative_or_missing_state_never_creates_directory(cfg,monkeypatch):
    from gauntlet_review.collaborative.store import Store
    for path in (Path("relative"),cfg.state_dir/"missing",cfg.repo_path/"inside"):
        with pytest.raises(CoreError) as error:
            Store.open(replace(cfg,state_dir=path),str(cfg.repo_path/".git"))
        assert error.value.code == "CONFIGURATION_ERROR"
        assert not path.exists()


def test_nonregular_database_and_unknown_schema_are_not_reinitialized(cfg):
    from gauntlet_review.collaborative.store import Store
    path=cfg.state_dir/Store.FILENAME
    path.mkdir()
    with pytest.raises(CoreError) as error:
        Store.open(cfg,str(cfg.repo_path/".git"))
    assert error.value.code == "CONFIGURATION_ERROR"
    path.rmdir()
    with sqlite3.connect(path) as connection:
        connection.execute("CREATE TABLE unrelated (value TEXT)")
        connection.execute("INSERT INTO unrelated VALUES ('preserve')")
    with pytest.raises(CoreError) as error:
        Store.open(cfg,str(cfg.repo_path/".git"))
    assert error.value.code == "UNSUPPORTED_SCHEMA"
    with sqlite3.connect(path) as connection:
        assert connection.execute("SELECT value FROM unrelated").fetchone()[0] == "preserve"


def test_same_column_names_do_not_authorize_an_altered_schema(store):
    from gauntlet_review.collaborative.store import Store
    with sqlite3.connect(store.path) as connection:
        connection.executescript("""
            ALTER TABLE retries RENAME TO saved_retries;
            CREATE TABLE retries(series_scope TEXT,participant TEXT,operation TEXT,key TEXT,
                request_sha256 TEXT,event_id TEXT,result_store_version INTEGER,result_bytes BLOB,result_sha256 TEXT);
            DROP TABLE saved_retries;
        """)
    with pytest.raises(CoreError) as error:
        Store.open(store.config,store.repo_binding)
    assert error.value.code == "UNSUPPORTED_SCHEMA"


@pytest.mark.anyio
async def test_recomputed_receipt_hash_cannot_hide_wrong_event_reference(store,append_event):
    await append_event(store)
    second=await append_event(store,key="second",expected_version=1)
    with sqlite3.connect(store.path) as connection:
        connection.execute("UPDATE retries SET event_id=? WHERE key='once'",(second.event_id,))
    with pytest.raises(CoreError) as error:
        await append_event(store)
    assert error.value.code == "CORRUPT_STATE"


@pytest.mark.anyio
async def test_raw_retry_receipt_corruption_refuses_replay(store,append_event):
    await append_event(store)
    with sqlite3.connect(store.path) as connection:
        raw=connection.execute("SELECT result_bytes FROM retries").fetchone()[0]
        changed=raw.replace(b'"accepted":true',b'"accepted":null')
        assert len(changed) == len(raw)
        connection.execute("UPDATE retries SET result_bytes=?",(changed,))
    with pytest.raises(CoreError) as error:
        await append_event(store)
    assert error.value.code == "DIGEST_MISMATCH"


@pytest.mark.anyio
async def test_valid_json_event_with_wrong_scope_is_corruption(store,append_event):
    from gauntlet_review.collaborative.contracts import encode
    await append_event(store)
    with sqlite3.connect(store.path) as connection:
        body=json.loads(connection.execute("SELECT body FROM events").fetchone()[0])
        body["series_scope"]="f"*64
        changed=encode(body)
        connection.execute("UPDATE events SET body=?,body_sha256=?",(changed,hashlib.sha256(changed).hexdigest()))
    with pytest.raises(CoreError) as error:
        store.read_series()
    assert error.value.code == "CORRUPT_STATE"


@pytest.mark.anyio
async def test_evidence_id_cannot_be_rebound_to_another_revision(store,append_event):
    await append_event(store)
    await append_event(store,key="proof",expected_version=1,operation="record_evidence",body=b"proof")
    with sqlite3.connect(store.path) as connection:
        connection.execute("UPDATE evidence SET revision_id=?",("f"*32,))
    with pytest.raises(CoreError) as error:
        store.read_series()
    assert error.value.code == "CORRUPT_STATE"


@pytest.mark.anyio
async def test_cursor_refuses_version_drift_and_cross_revision_reuse(store,append_event):
    await append_event(store)
    await append_event(store,key="second",expected_version=1)
    history=store.read_series()
    first=store.read_page(history.id,history.current_revision,"history",None,1)
    assert not first.complete and first.next_cursor
    second=store.read_page(history.id,history.current_revision,"history",first.next_cursor,1)
    assert second.complete and second.items[0]["seq"] == 2
    await append_event(store,key="third",expected_version=2)
    with pytest.raises(CoreError) as error:
        store.read_page(history.id,history.current_revision,"history",first.next_cursor,1)
    assert error.value.code == "CONFLICT"


@pytest.mark.anyio
async def test_private_state_directory_and_junction_components_are_checked(cfg,tmp_path):
    from gauntlet_review.collaborative.store import Store
    target=tmp_path/"target"
    target.mkdir(mode=0o700)
    child=target/"child"
    child.mkdir(mode=0o700)
    redirected=tmp_path/"redirected"
    if os.name == "nt":
        import _winapi
        _winapi.CreateJunction(str(target),str(redirected))
    else:
        redirected.symlink_to(target,target_is_directory=True)
    for state in (redirected,redirected/"child"):
        with pytest.raises(CoreError) as error:
            Store.open(replace(cfg,state_dir=state),str(cfg.repo_path/".git"))
        assert error.value.code == "CONFIGURATION_ERROR"
    assert not (target/Store.FILENAME).exists()
    assert not (child/Store.FILENAME).exists()


@pytest.mark.parametrize("suffix",["-journal","-wal","-shm"])
def test_nonregular_sidecars_are_preserved_and_refused(cfg,suffix):
    from gauntlet_review.collaborative.store import Store
    sidecar=cfg.state_dir/(Store.FILENAME+suffix)
    sidecar.mkdir()
    (sidecar/"preserve").write_bytes(b"unchanged")
    with pytest.raises(CoreError) as error:
        Store.open(cfg,str(cfg.repo_path/".git"))
    assert error.value.code == "CONFIGURATION_ERROR"
    assert (sidecar/"preserve").read_bytes() == b"unchanged"


@pytest.mark.anyio
async def test_initialization_race_does_not_duplicate_or_replace_metadata(cfg,git_fixture):
    import anyio
    from gauntlet_review.collaborative.source import GitSource
    from gauntlet_review.collaborative.store import Store
    with GitSource(cfg) as source:
        binding=source.repo_binding
    opened=[]
    async def create():
        value=await anyio.to_thread.run_sync(lambda:Store.open(cfg,binding))
        opened.append(value)
    async with anyio.create_task_group() as group:
        group.start_soon(create)
        group.start_soon(create)
    try:
        assert len(opened) == 2 and all(value.version() == 0 for value in opened)
        with sqlite3.connect(opened[0].path) as connection:
            assert connection.execute("SELECT COUNT(*) FROM meta").fetchone()[0] == 1
    finally:
        for value in opened:
            value.close()


@pytest.mark.anyio
async def test_malformed_retry_metadata_is_corruption_even_on_a_read(store,append_event):
    await append_event(store)
    with sqlite3.connect(store.path) as connection:
        connection.execute("UPDATE retries SET result_store_version=1.5")
    with pytest.raises(CoreError) as error:
        store.read_series()
    assert error.value.code == "CORRUPT_STATE"


def test_persisted_receipt_flags_do_not_coerce_integer_booleans():
    from pydantic import ValidationError
    from gauntlet_review.collaborative.contracts import OpenResult,InlineDescriptor
    with pytest.raises(ValidationError):
        OpenResult.model_validate({"accepted":1,"change_count":0,"manifest_digest":"a"*64},strict=True)
    with pytest.raises(ValidationError):
        InlineDescriptor.model_validate({"kind":"inline","length":0,"sha256":"a"*64,
                                         "bytes_verified":1,"claims_verified":0},strict=True)


@pytest.mark.anyio
async def test_nonblob_event_storage_returns_typed_corruption(store,append_event):
    await append_event(store)
    with sqlite3.connect(store.path) as connection:
        raw=connection.execute("SELECT body FROM events").fetchone()[0]
        connection.execute("UPDATE events SET body=?",(raw.decode("utf-8"),))
    with pytest.raises(CoreError) as error:
        store.read_series()
    assert error.value.code == "CORRUPT_STATE"


@pytest.mark.anyio
async def test_linked_worktree_replays_after_configured_ref_disappears(store,append_event,git_fixture,tmp_path):
    from dulwich.worktree import add_worktree
    from gauntlet_review.collaborative.source import GitSource
    from gauntlet_review.collaborative.store import Store
    first=await append_event(store)
    head=store.read_series().snapshot.header["source_oid"]
    linked=tmp_path/"linked-retry"
    add_worktree(git_fixture.repo,str(linked),commit=head.encode("ascii"),detach=True).close()
    del git_fixture.repo.refs[store.config.source_ref]
    config=replace(store.config,repo_path=linked)
    with GitSource(config) as source, Store.open(config,store.repo_binding) as linked_store:
        assert source.repo_binding == store.repo_binding
        replay=await append_event(linked_store,build_hook=lambda _:pytest.fail("retry read moved refs"))
        assert replay.replayed and replay.result_bytes == first.result_bytes
