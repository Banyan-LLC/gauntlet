import base64
from dataclasses import replace
import hashlib
import json
from pathlib import Path
import socket
import subprocess

import pytest

from gauntlet_review.collaborative.contracts import CoreError,Policy,encode

BLOCKER=dict(severity="blocking",location="file:1",issue="incorrect result",suggestion="fix result")


def assert_error(response,code):
    assert response["ok"] is False and response["error"]["code"] == code,response
    assert response["assurance"] == "collaborative-v1"
    assert response["result"] is None


@pytest.mark.anyio
async def test_two_independent_cores_preserve_findings_across_fix_and_fresh_closure(flow):
    initial=await flow.reviewer.review_status({})
    assert initial["ok"] and initial["result"]["series"] is None and initial["store_version"] == 0
    assert initial["review_id"] is None and initial["revision_id"] is None
    opened=await flow.open()
    assert opened["ok"] and opened["result"]["change_count"] == 1
    request=await flow.evidence_request()
    evidence=await flow.author.record_evidence(request)
    assert evidence["ok"] and evidence["result"]["content"]["bytes_verified"]
    first=await flow.submit(recommendations=[BLOCKER])
    assert first["ok"] and first["result"]["normalized_verdict"] == "request_changes"
    finding_id=first["result"]["new_finding_ids"][0]
    fixed=await flow.commit_fix()
    assert fixed["ok"] and fixed["review_id"] == opened["review_id"] and fixed["revision_id"]!=opened["revision_id"]
    pending=await flow.reviewer.review_status({})
    assert pending["result"]["status"] == "awaiting_review"
    assert pending["result"]["finding_rollups"][0]["id"] == finding_id
    closed=await flow.submit()
    assert closed["ok"] and "peer_complete" not in encode(closed).decode("utf-8")
    current=await flow.reviewer.review_status({})
    assert current["result"]["status"] == "peer_complete" and current["freshness"]["state"] == "match"
    assert current["result"]["finding_rollups"][0]["digest"] == pending["result"]["finding_rollups"][0]["digest"]
    page=await flow.author.read_review({**flow.bound(opened),"view":"evidence",
                                       "artifact_id":evidence["result"]["evidence_id"]})
    assert page["ok"] and base64.b64decode(page["result"]["data_b64"]) == b"proof"


@pytest.mark.anyio
async def test_roles_reject_disallowed_operations_even_without_server_registration(flow):
    await flow.open()
    request=await flow.verdict_request()
    assert_error(await flow.author.submit_review(request),"FORBIDDEN")
    assert_error(await flow.reviewer.open_review({"key":"other","expected_version":1}),"FORBIDDEN")
    assert flow.author.store.version() == 1


@pytest.mark.anyio
async def test_exact_retry_after_ref_drift_keeps_original_result_and_observation(flow):
    request={"key":"initial","expected_version":0}
    first=await flow.author.open_review(request)
    assert first["ok"]
    parent=flow.author.store.read_series().snapshot.header["source_oid"]
    same_tree=flow.writer.commit({b"file":(0o100644,b"one")},parents=[parent])
    flow.writer.set_ref(flow.config.source_ref,same_tree)
    again=await flow.author.open_review(request)
    assert again["ok"] and again["result"] == first["result"] and again["store_version"] == first["store_version"]
    assert again["freshness"] == {"state":"not_checked"}
    assert (await flow.reviewer.review_status({}))["result"]["status"] == "stale"


@pytest.mark.anyio
async def test_missing_source_after_approval_never_reports_peer_completion(flow):
    await flow.open()
    await flow.submit()
    snapshot=flow.author.store.read_series().snapshot
    oid=snapshot.changes[0].new_oid
    (flow.config.repo_path/".git"/"objects"/oid[:2]/oid[2:]).unlink()
    response=await flow.reviewer.review_status({})
    assert_error(response,"MISSING_OBJECT")
    assert response["freshness"] == {"state":"unknown"}


@pytest.mark.anyio
@pytest.mark.parametrize("failure,code",[("missing","MISSING_OBJECT"),("corrupt","DIGEST_MISMATCH")])
async def test_unavailable_unchanged_context_cannot_leave_peer_complete(flow,failure,code):
    import zlib
    from dulwich.objects import Blob
    stable=b"unchanged context"
    flow.writer.pair({b"stable":(0o100644,stable)},
                     {b"stable":(0o100644,stable),b"file":(0o100644,b"new")})
    await flow.open()
    accepted=await flow.submit(recommendations=[dict(severity="nit",location="file:1",
        issue="preserved original note",suggestion="review later")])
    assert accepted["ok"]
    assert (await flow.reviewer.review_status({}))["result"]["status"]=="peer_complete"
    before=flow.author.store.read_series()
    oid=Blob.from_string(stable).id.decode()
    path=flow.config.repo_path/".git"/"objects"/oid[:2]/oid[2:]
    if failure=="missing":
        path.unlink()
    else:
        path.write_bytes(zlib.compress(b"blob 5\0other"))
    response=await flow.reviewer.review_status({})
    assert_error(response,code)
    assert response["freshness"]=={"state":"unknown"}
    assert flow.author.store.read_series()==before


@pytest.mark.anyio
async def test_evidence_and_verdict_refuse_superseded_revision(flow):
    await flow.open()
    evidence=await flow.evidence_request()
    verdict=await flow.verdict_request()
    await flow.commit_fix()
    version=(await flow.author.review_status({}))["store_version"]
    assert_error(await flow.author.record_evidence({**evidence,"expected_version":version}),"STALE")
    assert_error(await flow.reviewer.submit_review({**verdict,"expected_version":version}),"STALE")


@pytest.mark.anyio
async def test_external_archive_stays_unopened_and_unverified(flow,monkeypatch):
    await flow.open()
    def forbidden(*args,**kwargs):
        raise AssertionError("external operation attempted")
    monkeypatch.setattr(subprocess,"Popen",forbidden)
    monkeypatch.setattr(socket.socket,"connect",forbidden)
    request=await flow.evidence_request(content={"kind":"external","uri":"https://127.0.0.1/private",
                                               "length":2**53-1,"sha256":"a"*64},origin="ci_receipt")
    response=await flow.author.record_evidence(request)
    assert response["ok"]
    assert response["result"]["content"]["verified"] is False
    assert response["result"]["content"]["claims_verified"] is False
    assert (await flow.reviewer.review_status({}))["result"]["status"] == "awaiting_review"


@pytest.mark.anyio
async def test_read_only_both_side_handles_and_complete_byte_pages(flow):
    body=b"x"*65536+b"\0tail"
    flow.writer.pair({b"deleted":(0o100644,b"old"),b"changed":(0o100644,b"base")},
                     {b"changed":(0o100755,body),b"link":(0o120000,b"target")})
    opened=await flow.open()
    assert opened["ok"]
    before=flow.author.store.version()
    rows=await flow.listing(opened,"manifest",limit=1)
    reconstructed=[]
    for row in rows:
        for handle in (row["old_artifact"],row["new_artifact"]):
            if handle is None:
                continue
            data=bytearray()
            while True:
                page=await flow.reviewer.read_review({**flow.bound(opened),"view":"artifact",
                    "artifact_id":handle["artifact_id"],"offset":len(data),"length":65536})
                assert page["ok"],page
                assert page["freshness"] == {"state":"not_checked"}
                value=page["result"]
                data.extend(base64.b64decode(value["data_b64"],validate=True))
                assert len(encode({k:v for k,v in value.items() if k!="data_b64"}))<=4096
                if value["eof"]:
                    break
                assert value["length"]>0
            assert hashlib.sha256(data).hexdigest() == handle["sha256"]
            reconstructed.append(bytes(data))
    assert set(reconstructed) == {b"old",b"base",body,b"target"}
    assert flow.author.store.version() == before


@pytest.mark.anyio
async def test_history_descriptors_link_exact_canonical_event_bodies(flow):
    await flow.open()
    await flow.submit(recommendations=[BLOCKER])
    status=await flow.reviewer.review_status({})
    rows=await flow.listing(status,"history",limit=1)
    assert [row["seq"] for row in rows] == [1,2]
    for row in rows:
        response=await flow.reviewer.read_review({"review_id":status["review_id"],"revision_id":row["revision_id"],
            "snapshot_digest":row["snapshot_digest"],"view":"artifact","artifact_id":row["artifact_id"]})
        assert response["ok"],response
        body=base64.b64decode(response["result"]["data_b64"])
        assert len(body) == row["length"] and hashlib.sha256(body).hexdigest() == row["sha256"]
        assert encode(json.loads(body)) == body


@pytest.mark.anyio
async def test_cursor_version_drift_is_conflict_without_mixed_pages(flow):
    await flow.open()
    await flow.submit()
    before=await flow.reviewer.review_status({})
    first=await flow.reviewer.read_review({**flow.bound(before),"view":"history","limit":1})
    assert first["ok"] and first["result"]["next_cursor"]
    await flow.author.record_evidence(await flow.evidence_request())
    next_page=await flow.reviewer.read_review({**flow.bound(before),"view":"history","limit":1,
                                              "cursor":first["result"]["next_cursor"]})
    assert_error(next_page,"CONFLICT")


@pytest.mark.anyio
async def test_early_replay_refuses_changed_resource_binding(flow,monkeypatch,tmp_path):
    request={"key":"initial","expected_version":0}
    assert (await flow.author.open_review(request))["ok"]
    monkeypatch.setattr(flow.author.source,"repo_binding",str(tmp_path/"other-git"))
    assert_error(await flow.author.open_review(request),"CONFIGURATION_MISMATCH")


@pytest.mark.anyio
async def test_invalid_input_and_unexpected_errors_do_not_echo_bodies(flow,monkeypatch,capsys):
    invalid=await flow.author.open_review({"key":"private-source-content","expected_version":True})
    assert_error(invalid,"INVALID_ARGUMENT")
    assert "private-source-content" not in encode(invalid).decode()
    def failure(*args,**kwargs):
        raise RuntimeError("private-source-content")
    monkeypatch.setattr(flow.author.source,"capture",failure)
    unexpected=await flow.open()
    assert_error(unexpected,"INTERNAL_ERROR")
    assert "private-source-content" not in encode(unexpected).decode()
    captured=capsys.readouterr()
    assert "private-source-content" not in captured.out+captured.err


def test_core_rejects_relative_configuration_before_using_supplied_resources(cfg):
    from gauntlet_review.collaborative.core import ReviewCore
    with pytest.raises(CoreError) as error:
        ReviewCore(replace(cfg,state_dir=Path("relative")),None,None,Policy())
    assert error.value.code == "CONFIGURATION_ERROR"


@pytest.mark.anyio
async def test_unchanged_oversized_blob_refuses_admission_without_a_partial_revision(flow):
    unchanged=b"x"*(4*1024*1024+1)
    flow.writer.pair({b"z-large":(0o100644,unchanged)},
                     {b"z-large":(0o100644,unchanged),b"a-small":(0o100644,b"small")})
    opened=await flow.open()
    assert_error(opened,"LIMIT_EXCEEDED")
    assert opened["error"]["detail"]=={"limit":"blob_bytes"}
    assert opened["store_version"]==0 and opened["review_id"] is None
    assert flow.author.store.read_series() is None


@pytest.mark.anyio
async def test_listing_byte_budget_produces_progress_and_complete_continuation(flow):
    files={b"x"*4092+f"{index:04d}".encode():(0o100644,b"x") for index in range(20)}
    flow.writer.pair({},files)
    opened=await flow.open()
    assert opened["ok"],opened
    first=await flow.reviewer.read_review({**flow.bound(opened),"view":"manifest","limit":100})
    assert first["ok"] and 0<len(first["result"]["items"])<20
    assert not first["result"]["complete"] and len(encode(first))<=80*1024
    rows=await flow.listing(opened,"manifest")
    assert len(rows) == 20 and len({row["change"]["change_id"] for row in rows}) == 20


@pytest.mark.anyio
async def test_artifact_collision_refuses_admission_including_unchanged_head_files(flow,monkeypatch):
    flow.writer.pair({b"unchanged":(0o100644,b"same")},
                     {b"unchanged":(0o100644,b"same"),b"added":(0o100644,b"new")})
    monkeypatch.setattr(flow.author.source,"_artifact_id",lambda *args:"f"*32)
    assert_error(await flow.open(),"DIGEST_MISMATCH")
    assert flow.author.store.version() == 0


@pytest.mark.anyio
async def test_two_hundred_maximal_findings_stay_visible_and_history_bytes_reconstruct(store,append_event,append_verdict):
    from gauntlet_review.collaborative.core import ReviewCore
    from gauntlet_review.collaborative.source import GitSource
    from mcp_types import CallToolResult
    await append_event(store)
    recommendation=dict(severity="nit",location="\\"*150,issue="\\"*500,suggestion="\\"*500)
    for _ in range(10):
        await append_verdict(store,recommendations=[recommendation]*20,reason="\\"*256)
    with GitSource(store.config) as source:
        core=ReviewCore(store.config,source,store,store.policy)
        current=await core.review_status({})
        assert current["ok"] and current["result"]["status"] == "peer_complete"
        assert len(current["result"]["finding_rollups"]) == 200
        def bounded(response):
            result=CallToolResult.model_validate({"content":[{"type":"text","text":encode(response).decode("utf-8")}],
                                                 "structuredContent":response,"isError":not response["ok"]})
            assert len(result.model_dump_json(by_alias=True,exclude_none=True).encode("utf-8"))<=256*1024
        bounded(current)
        bound={key:current[key] for key in ("review_id","revision_id","snapshot_digest")}
        history=await core.read_review({**bound,"view":"history"})
        assert history["ok"] and history["result"]["complete"]
        originals={event.id:event.body for event in store.read_series().events}
        for descriptor in history["result"]["items"]:
            data=bytearray()
            while True:
                response=await core.read_review({**bound,"view":"artifact","artifact_id":descriptor["artifact_id"],
                                                 "offset":len(data),"length":65536})
                assert response["ok"],response
                bounded(response)
                page=response["result"]
                data.extend(base64.b64decode(page["data_b64"]))
                if page["eof"]:
                    break
                assert page["length"]>0
            assert bytes(data) == originals[descriptor["id"]]
            assert hashlib.sha256(data).hexdigest() == descriptor["sha256"]


def test_direct_core_cannot_raise_fixed_profile_limits(flow,monkeypatch):
    from gauntlet_review.collaborative.core import ReviewCore
    changed=replace(Policy(),findings=201)
    monkeypatch.setattr(flow.author.source,"policy",changed)
    monkeypatch.setattr(flow.author.store,"policy",changed)
    with pytest.raises(CoreError) as error:
        ReviewCore(flow.author.config,flow.author.source,flow.author.store,changed)
    assert error.value.code == "CONFIGURATION_MISMATCH"


@pytest.mark.anyio
async def test_lost_mutation_response_replays_without_rechecking_moved_refs(flow,monkeypatch):
    request={"key":"uncertain","expected_version":0}
    commit=flow.author.store._commit
    def lost(connection):
        commit(connection)
        raise OSError("response lost after durable COMMIT")
    monkeypatch.setattr(flow.author.store,"_commit",lost)
    unknown=await flow.author.open_review(request)
    assert_error(unknown,"STORAGE_ERROR")
    assert unknown["freshness"] == {"state":"unknown"}
    monkeypatch.setattr(flow.author.store,"_commit",commit)
    history=flow.author.store.read_series()
    head=flow.writer.commit({b"file":(0o100644,b"later")},parents=[history.snapshot.header["source_oid"]])
    flow.writer.set_ref(flow.config.source_ref,head)
    recovered=await flow.author.open_review(request)
    assert recovered["ok"] and recovered["freshness"] == {"state":"not_checked"}
    assert flow.author.store.version() == 1 and len(flow.author.store.read_series().events) == 1


@pytest.mark.anyio
async def test_last_ref_check_before_commit_rolls_back_a_moved_capture(flow,monkeypatch):
    count=0
    async def checkpoint():
        nonlocal count
        count+=1
        if count==3:
            parent=flow.writer.repo.refs[flow.config.source_ref].decode("ascii")
            head=flow.writer.commit({b"file":(0o100644,b"moved")},parents=[parent])
            flow.writer.set_ref(flow.config.source_ref,head)
    monkeypatch.setattr(flow.author,"_checkpoint",checkpoint)
    response=await flow.author.open_review({"key":"moving","expected_version":0})
    assert_error(response,"STALE")
    assert response["review_id"] is None and response["revision_id"] is None
    assert flow.author.store.version() == 0 and flow.author.store.read_series() is None


@pytest.mark.anyio
async def test_denied_object_read_is_an_unknown_freshness_error_without_prefix(flow,monkeypatch):
    opened=await flow.open()
    rows=await flow.listing(opened,"manifest")
    handle=rows[0]["new_artifact"]
    def denied(*args,**kwargs):
        raise PermissionError(13,"private-source-content")
    monkeypatch.setattr(flow.reviewer.source,"_blob",denied)
    response=await flow.reviewer.read_review({**flow.bound(opened),"view":"artifact","artifact_id":handle["artifact_id"]})
    assert_error(response,"STORAGE_ERROR")
    assert response["freshness"] == {"state":"unknown"}
    assert "private-source-content" not in encode(response).decode()


@pytest.mark.anyio
async def test_client_approval_flag_is_never_a_status_input(flow):
    await flow.open()
    response=await flow.reviewer.review_status({"approved":True})
    assert_error(response,"INVALID_ARGUMENT")
    assert (await flow.reviewer.review_status({}))["result"]["status"] == "awaiting_review"
