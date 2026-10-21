from dataclasses import asdict,replace
import hashlib
import json
import sqlite3

import pytest

from gauntlet_review.collaborative.contracts import CoreError,RefObservation,encode,verdict_capacity

BLOCKER=dict(severity="blocking",location="file:1",issue="original issue",suggestion="original fix")
NIT=dict(severity="nit",location="file:2",issue="nit issue",suggestion="nit fix")


def prepare(history,request):
    from gauntlet_review.collaborative.policy import prepare_verdict
    return prepare_verdict(history,request,history.snapshot)


def status(history,*,source_oid=None,target_oid=None):
    from gauntlet_review.collaborative.policy import derive_status
    observation=RefObservation(source_oid or history.snapshot.header["source_oid"],
        target_oid or history.snapshot.header["target_oid"],"2026-10-21T12:00:00+00:00")
    return derive_status(history,observation)


@pytest.mark.anyio
async def test_disputed_blocker_stays_changes_requested(store,append_event,append_verdict,verdict_factory):
    await append_event(store)
    await append_verdict(store,recommendations=[BLOCKER])
    history=store.read_series()
    request=verdict_factory(history,verdict="approve",disposition="disputed")
    accepted=prepare(history,request)
    assert accepted.status == "changes_requested"
    assert accepted.carryover[0]["reason"]
    await append_verdict(store,verdict="approve",disposition="disputed")
    assert status(store.read_series()).status == "changes_requested"


@pytest.mark.anyio
async def test_new_non_nit_normalizes_approval_and_preserves_legacy_id_scheme(store,append_event,append_verdict):
    from gauntlet_review.verdict import recommendation_id
    await append_event(store)
    result=await append_verdict(store,verdict="approve",recommendations=[BLOCKER])
    receipt=json.loads(result.result_bytes)
    assert receipt["result"]["normalized_verdict"] == "request_changes"
    history=store.read_series()
    record=history.findings[0]["record"]
    assert record["id"] == recommendation_id(1,0,BLOCKER)
    assert record["review_id"] == history.id and record["revision_id"] == history.current_revision
    assert {key:record[key] for key in BLOCKER} == BLOCKER
    assert history.findings[0]["digest"] == hashlib.sha256(encode(record)).hexdigest()
    assert status(history).status == "changes_requested"


@pytest.mark.anyio
async def test_every_addressed_and_nit_finding_must_recur_and_can_reopen(store,append_event,append_verdict,verdict_factory):
    await append_event(store)
    await append_verdict(store,recommendations=[BLOCKER,NIT])
    originals=store.read_series().findings
    await append_verdict(store,disposition="addressed")
    history=store.read_series()
    assert status(history).status == "peer_complete" and len(status(history).finding_rollups) == 2
    for index in (0,1):
        request=verdict_factory(history).model_dump(mode="json")
        request["carryover"].pop(index)
        with pytest.raises(CoreError) as error:
            prepare(history,request)
        assert error.value.code == "INVALID_ARGUMENT"
    await append_verdict(store,disposition="outstanding",reason="regression confirmed")
    reopened=store.read_series()
    assert status(reopened).status == "changes_requested"
    assert [f["record"] for f in reopened.findings] == [f["record"] for f in originals]
    assert [f["digest"] for f in reopened.findings] == [f["digest"] for f in originals]


@pytest.mark.anyio
@pytest.mark.parametrize("defect",["unknown","duplicate","digest","replacement"])
async def test_carryover_cannot_omit_replace_or_reidentify_original_findings(store,append_event,append_verdict,verdict_factory,defect):
    await append_event(store)
    await append_verdict(store,recommendations=[BLOCKER])
    history=store.read_series()
    request=verdict_factory(history).model_dump(mode="json")
    if defect=="unknown":
        request["carryover"][0]["id"]="r1-"+"f"*32
    elif defect=="duplicate":
        request["carryover"]*=2
    elif defect=="digest":
        request["carryover"][0]["digest"]="f"*64
    else:
        request["carryover"][0]["issue"]="replacement text"
    with pytest.raises(CoreError) as error:
        prepare(history,request)
    assert error.value.code == ("DIGEST_MISMATCH" if defect=="digest" else "INVALID_ARGUMENT")


@pytest.mark.anyio
async def test_coverage_includes_modified_deleted_mode_symlink_and_gitlink_changes(store,git_fixture,append_event,verdict_factory):
    old={b"deleted":(0o100644,b"gone"),b"mode":(0o100644,b"same"),b"modified":(0o100644,b"old")}
    new={b"mode":(0o100755,b"same"),b"modified":(0o100644,b"new"),b"link":(0o120000,b"target"),b"sub":(0o160000,b"e"*40)}
    git_fixture.pair(old,new)
    await append_event(store)
    history=store.read_series()
    assert len(history.snapshot.changes) == 5
    for change in history.snapshot.changes:
        request=verdict_factory(history).model_dump(mode="json")
        request["coverage"].remove(change.change_id)
        with pytest.raises(CoreError) as error:
            prepare(history,request)
        assert error.value.code == "INVALID_ARGUMENT"
    assert prepare(history,verdict_factory(history)).normalized_verdict == "approve"


@pytest.mark.anyio
async def test_new_revision_drops_approval_but_preserves_findings_and_stale_precedes_status(store,append_event,append_verdict):
    await append_event(store)
    await append_verdict(store,recommendations=[NIT])
    old=store.read_series()
    assert status(old).status == "peer_complete"
    await append_event(store,key="next",expected_version=old.store_version)
    history=store.read_series()
    assert history.findings == old.findings
    assert status(history).status == "awaiting_review"
    assert status(history,source_oid="f"*40).status == "stale"
    assert status(history,target_oid="f"*40).status == "stale"
    assert status(history).freshness["state"] == "match"


@pytest.mark.anyio
async def test_request_changes_without_findings_still_requests_changes(store,append_event,append_verdict):
    await append_event(store)
    await append_verdict(store,verdict="request_changes")
    assert status(store.read_series()).status == "changes_requested"


@pytest.mark.anyio
async def test_repeated_text_has_distinct_round_and_index_ids(store,append_event,append_verdict):
    await append_event(store)
    await append_verdict(store,recommendations=[NIT,NIT])
    await append_verdict(store,recommendations=[NIT])
    findings=store.read_series().findings
    assert len({f["record"]["id"] for f in findings}) == 3
    assert [f["record"]["round"] for f in findings] == [1,1,2]


@pytest.mark.anyio
async def test_maximum_reachable_ledger_closes_on_round_ten(store,git_fixture,append_event,append_verdict):
    git_fixture.pair({}, {f"file-{n:04d}".encode("ascii"):(0o100644,b"x") for n in range(1000)})
    await append_event(store)
    recommendation=dict(severity="important",location="\\"*145+"😀x",issue="\\"*496+"😀",suggestion="\\"*500)
    for _ in range(9):
        await append_verdict(store,recommendations=[recommendation]*20,disposition="outstanding",reason="\\"*256)
    assert len(store.read_series().findings) == 180
    await append_verdict(store,disposition="addressed",reason="\\"*256,summary="\\"*796+"😀")
    history=store.read_series()
    assert history.verdict_count == 10 and status(history).status == "peer_complete"
    assert len(status(history).finding_rollups) == 180
    assert verdict_capacity(200) == 218196


@pytest.mark.anyio
async def test_200_findings_and_tenth_verdict_cannot_reset_limits_by_reopening(store,append_event,append_verdict):
    await append_event(store)
    for _ in range(10):
        await append_verdict(store,recommendations=[NIT]*20)
    before=store.read_series()
    assert len(before.findings) == 200 and before.verdict_count == 10
    for recommendations,limit in (([NIT],"findings"),([],"verdicts")):
        with pytest.raises(CoreError) as error:
            await append_verdict(store,recommendations=recommendations)
        assert error.value.code == "LIMIT_EXCEEDED" and error.value.detail["limit"] == limit
    assert store.read_series() == before
    await append_event(store,key="reopen",expected_version=before.store_version)
    reopened=store.read_series()
    assert reopened.id == before.id and reopened.verdict_count == 10 and len(reopened.findings) == 200
    with pytest.raises(CoreError) as error:
        await append_verdict(store)
    assert error.value.code == "LIMIT_EXCEEDED"


@pytest.mark.anyio
async def test_twentieth_revision_is_preserved_when_twenty_first_refused(store,append_event,git_fixture):
    await append_event(store)
    for revision in range(2,21):
        history=store.read_series()
        parent=history.snapshot.header["source_oid"]
        new=git_fixture.commit({b"file":(0o100644,f"version {revision}".encode())},parents=[parent])
        git_fixture.set_ref(store.config.source_ref,new)
        await append_event(store,key=f"revision_{revision}",expected_version=history.store_version)
    before=store.read_series()
    assert before.revision_count == 20
    with pytest.raises(CoreError) as error:
        await append_event(store,key="revision_21",expected_version=before.store_version)
    assert error.value.code == "LIMIT_EXCEEDED"
    assert store.read_series() == before


@pytest.mark.anyio
@pytest.mark.parametrize("field,value,code",[("review_id","f"*32,"NOT_FOUND"),
    ("revision_id","f"*32,"STALE"),("snapshot_digest","f"*64,"STALE"),
    ("coverage_digest","f"*64,"INVALID_ARGUMENT"),("coverage",["f"*32],"INVALID_ARGUMENT")])
async def test_verdict_cannot_cross_review_revision_snapshot_or_manifest(store,append_event,verdict_factory,field,value,code):
    await append_event(store)
    history=store.read_series()
    request=verdict_factory(history,**{field:value})
    with pytest.raises(CoreError) as error:
        prepare(history,request)
    assert error.value.code == code


@pytest.mark.anyio
async def test_stored_finding_text_cannot_change_under_a_valid_event_hash(store,append_event,append_verdict):
    await append_event(store)
    await append_verdict(store,recommendations=[NIT])
    with sqlite3.connect(store.path) as connection:
        row=connection.execute("SELECT id,body FROM events WHERE kind='submit_review'").fetchone()
        value=json.loads(row[1])
        value["data"]["recommendations"][0]["record"]["issue"]="bad issue"
        changed=encode(value)
        assert len(changed) == len(row[1])
        connection.execute("UPDATE events SET body=?,body_sha256=? WHERE id=?",(changed,hashlib.sha256(changed).hexdigest(),row[0]))
    with pytest.raises(CoreError) as error:
        store.read_series()
    assert error.value.code == "CORRUPT_STATE"


@pytest.mark.anyio
async def test_verdict_retry_receipt_must_name_the_committed_finding_ids(store,append_event,append_verdict):
    from gauntlet_review.collaborative.store import Store
    await append_event(store)
    await append_verdict(store,recommendations=[NIT])
    with sqlite3.connect(store.path) as connection:
        row=connection.execute("SELECT key,request_sha256,result_bytes FROM retries WHERE operation='submit_review'").fetchone()
        value=json.loads(row[2])
        value["result"]["new_finding_ids"][0]="r1-"+"f"*32
        changed=encode(value)
        assert len(changed) == len(row[2])
        connection.execute("UPDATE retries SET result_bytes=?,result_sha256=? WHERE operation='submit_review'",
                           (changed,hashlib.sha256(changed).hexdigest()))
    config=replace(store.config,participant="peer",role="reviewer")
    with Store.open(config,store.repo_binding) as reviewer:
        with pytest.raises(CoreError) as error:
            reviewer.lookup_retry(config.series_scope,config.participant,"submit_review",row[0],row[1])
        assert error.value.code == "CORRUPT_STATE"
