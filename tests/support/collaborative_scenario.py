"""Disposable integration/fault workers. No production crash switch exists."""
from __future__ import annotations

import base64
from dataclasses import replace
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/"gauntlet-review/python/tests/collaborative"))
from conftest import GitFixture
from collaborative_process import ExpectedExit,OwnedTransport,checkpoint,run_case


def server_args(config,role):
    return ["-m","gauntlet_review.collaborative","--repo",str(config.repo_path),
            "--state-dir",str(config.state_dir),"--repository-id",config.repository_id,
            "--source-ref",config.source_ref.decode(),"--target-ref",config.target_ref.decode(),
            "--participant","author" if role=="author" else "peer","--role",role]


def bound(value):
    return {name:value[name] for name in ("review_id","revision_id","snapshot_digest")}


async def call(client,name,request):
    from gauntlet_review.collaborative.contracts import encode
    response=await client.call_tool(name,{"request":request})
    value=response.structured_content
    assert value["ok"] and not response.is_error,value
    assert response.content[0].text.encode()==encode(value)
    assert len(response.model_dump_json(by_alias=True,exclude_none=True).encode())<=256*1024
    return value


async def listing(client,pinned,view):
    items,cursor=[],None
    while True:
        response=await call(client,"read_review",{**bound(pinned),"view":view,"limit":1,"cursor":cursor})
        page=response["result"]
        items.extend(page["items"])
        if page["complete"]:
            assert page["next_cursor"] is None
            return items
        assert page["items"] and page["next_cursor"]!=cursor
        cursor=page["next_cursor"]


async def body(client,pinned,artifact_id,view="artifact"):
    data=bytearray()
    while True:
        response=await call(client,"read_review",{**bound(pinned),"view":view,
            "artifact_id":artifact_id,"offset":len(data),"length":65536})
        page=response["result"]
        data.extend(base64.b64decode(page["data_b64"],validate=True))
        if page["eof"]:
            assert len(data)==page["total"] and hashlib.sha256(data).hexdigest()==page["sha256"]
            return bytes(data)


async def two_hosts(config):
    from mcp import Client
    writer=GitFixture(config)
    pids=[]
    def transport(role):
        return OwnedTransport([sys.executable,*server_args(config,role)],cwd=ROOT)
    author_transport,peer_transport=transport("author"),transport("reviewer")
    try:
        async with Client(author_transport) as author,Client(peer_transport) as peer:
            pids.extend([author_transport.outcome.pid,peer_transport.outcome.pid])
            initial=await call(peer,"review_status",{})
            assert initial["result"]["series"] is None
            opened=await call(author,"open_review",{"key":"initial","expected_version":0})
            manifest=await listing(peer,opened,"manifest")
            for row in manifest:
                for side in ("old_artifact","new_artifact"):
                    if row[side]:
                        await body(peer,opened,row[side]["artifact_id"])
            evidence=await call(author,"record_evidence",{**bound(opened),"key":"proof","expected_version":1,
                "origin":"agent_report","command":"fixture","runtime":"Python","exit_status":0,
                "content":{"kind":"inline","data_b64":base64.b64encode(b"original proof\0").decode()}})
            blocked=await call(peer,"submit_review",{**bound(opened),"key":"blocker","expected_version":2,
                "verdict":"approve","summary":"both source surfaces read","coverage_digest":opened["snapshot_digest"],
                "coverage":[row["change"]["change_id"] for row in manifest],"carryover":[],
                "recommendations":[{"severity":"blocking","location":"file:1","issue":"one is incorrect","suggestion":"use fixed"}]})
            assert blocked["result"]["normalized_verdict"]=="request_changes"
            writer.write_worktree_file("file",b"uncommitted secret")
            assert (await call(peer,"review_status",{}))["freshness"]["state"]=="match"
            assert await body(peer,opened,manifest[0]["new_artifact"]["artifact_id"])==b"one"
            original_head=writer.repo.refs[config.source_ref].decode()
            fixed=writer.commit({b"file":(0o100644,b"fixed")},parents=[original_head])
            writer.set_ref(config.source_ref,fixed)
            revised=await call(author,"open_review",{"key":"fixed","expected_version":3})
            pending=await call(peer,"review_status",{})
            assert pending["result"]["status"]=="awaiting_review"
            changed=await listing(peer,revised,"manifest")
            for row in changed:
                for side in ("old_artifact","new_artifact"):
                    if row[side]:
                        await body(peer,revised,row[side]["artifact_id"])
            carryover=[{"id":f["id"],"digest":f["digest"],"status":"addressed","reason":"read the committed fix"}
                       for f in pending["result"]["finding_rollups"]]
            accepted=await call(peer,"submit_review",{**bound(revised),"key":"closed","expected_version":4,
                "verdict":"approve","summary":"fixed bytes read","recommendations":[],"carryover":carryover,
                "coverage_digest":revised["snapshot_digest"],"coverage":[r["change"]["change_id"] for r in changed]})
            assert "peer_complete" not in json.dumps(accepted)
            current=await call(peer,"review_status",{})
            assert current["result"]["status"]=="peer_complete"
            events=await listing(peer,revised,"history")
            original_bodies={row["id"]:await body(peer,{"review_id":revised["review_id"],**row},row["artifact_id"]) for row in events}
            assert any(b"one is incorrect" in value for value in original_bodies.values())
            proof=evidence["result"]["evidence_id"]
            assert await body(peer,opened,proof,"evidence")==b"original proof\0"
        assert author_transport.outcome.completed and peer_transport.outcome.completed
        author_transport,peer_transport=transport("author"),transport("reviewer")
        async with Client(author_transport) as author,Client(peer_transport) as peer:
            pids.extend([author_transport.outcome.pid,peer_transport.outcome.pid])
            assert (await call(peer,"review_status",{}))["result"]["status"]=="peer_complete"
            again=await listing(peer,revised,"history")
            assert {r["id"]:await body(peer,{"review_id":revised["review_id"],**r},r["artifact_id"]) for r in again}==original_bodies
            assert await body(peer,opened,proof,"evidence")==b"original proof\0"
            assert await body(peer,opened,manifest[0]["old_artifact"]["artifact_id"])==b"old"
            assert await body(peer,opened,manifest[0]["new_artifact"]["artifact_id"])==b"one"
            next_head=writer.commit({b"file":(0o100644,b"next")},parents=[fixed])
            writer.set_ref(config.source_ref,next_head)
            head_drift=(await call(peer,"review_status",{}))["result"]["status"]
            replay=await call(author,"open_review",{"key":"initial","expected_version":0})
            assert replay["result"]==opened["result"] and replay["freshness"]=={"state":"not_checked"}
            writer.set_ref(config.source_ref,fixed)
            writer.set_ref(config.target_ref,original_head)
            target_drift=(await call(peer,"review_status",{}))["result"]["status"]
        assert author_transport.outcome.completed and peer_transport.outcome.completed
        print(json.dumps({"pids":pids,"status":current["result"]["status"],"events":len(events),
                          "head_drift":head_drift,"target_drift":target_drift}))
    finally:
        writer.repo.close()


async def crash_or_recover(config,scenario):
    from gauntlet_review.collaborative.contracts import Policy
    from gauntlet_review.collaborative.core import ReviewCore
    from gauntlet_review.collaborative.source import GitSource
    from gauntlet_review.collaborative.store import Store
    with GitSource(config) as source,Store.open(config,source.repo_binding) as store:
        core=ReviewCore(config,source,store,Policy())
        request={"key":"crash","expected_version":0}
        before=store.version()
        if not scenario.startswith("recover-"):
            original=store._commit
            def crash(connection):
                if scenario=="after-commit":
                    original(connection)
                checkpoint(scenario)
                os._exit(73)
            store._commit=crash
        response=await core.open_review(request)
        assert response["ok"],response
        if before:
            assert response["freshness"]=={"state":"not_checked"}
        again=await core.open_review(request)
        assert again["result"]==response["result"] and again["store_version"]==1
        print(json.dumps({"before":before,"after":store.version(),"events":len(store.read_series().events)}))
        core.close()


def raw_protocol(config):
    environment=dict(os.environ)
    secret="SOURCE-BODY-MUST-NOT-LEAK"
    environment["GAUNTLET_TEST_STDIN"]=secret+'\n'+json.dumps({"jsonrpc":"2.0","id":1,"method":"unknown/method","params":{}})+'\n'
    environment["GAUNTLET_TEST_CLOSE_STDIN"]="1"
    result=run_case([sys.executable,*server_args(config,"author")],cwd=ROOT,
                    environment=environment,deadline_seconds=30,expected=ExpectedExit())
    assert result.completed and result.tree_retired
    assert secret.encode() not in result.stdout.prefix+result.stderr.prefix
    assert b"Traceback" not in result.stderr.prefix
    responses=[json.loads(line) for line in result.stdout.prefix.splitlines()]
    assert responses and all("error" in response and "result" not in response for response in responses)
    print(json.dumps({"safe":True,"responses":responses}))


def main():
    from gauntlet_review.collaborative.contracts import OperatorConfig
    import anyio
    scenario,repo,state=sys.argv[1:]
    config=OperatorConfig(Path(repo),Path(state),"fixture",b"refs/heads/topic",b"refs/heads/main","author","author")
    if scenario=="two-hosts":
        anyio.run(two_hosts,config)
    elif scenario=="raw-protocol":
        raw_protocol(config)
    else:
        anyio.run(crash_or_recover,config,scenario)


if __name__=="__main__":
    main()
