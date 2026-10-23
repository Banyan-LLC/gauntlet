"""Model-free verifier fixtures use real core transactions and typed MCP history."""
import base64
from copy import deepcopy
from dataclasses import replace
import importlib.util
import json
from pathlib import Path
import sys

import pytest
pytest.importorskip("openai_codex")
from openai_codex.generated.v2_all import McpToolCallThreadItem

SUPPORT=Path(__file__).resolve().parents[4]/"tests/support"
sys.path.insert(0,str(SUPPORT))
from collaborative_acceptance import AcceptanceError,verify_live,verify_restart_recovery
from gauntlet_review.collaborative.contracts import Policy,encode
from gauntlet_review.collaborative.core import ReviewCore
from gauntlet_review.collaborative.source import GitSource
from gauntlet_review.collaborative.store import Store

pytestmark=pytest.mark.anyio


def bound(value):
    return {key:value[key] for key in ("review_id","revision_id","snapshot_digest")}


def receipt(result):
    return {"content":[{"type":"text","text":encode(result).decode()}],"structuredContent":result}


class Fixture:
    def __init__(self,config):
        from dulwich.repo import Repo
        config.operator.repo_path.mkdir(); config.operator.state_dir.mkdir(mode=0o700)
        Repo.init(str(config.operator.repo_path)).close()
        path=Path(__file__).parents[1]/"collaborative/conftest.py"
        spec=importlib.util.spec_from_file_location("acceptance_git_fixture",path)
        module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        self.git=module.GitFixture(config.operator)
        self.files={b"README":(0o100644,b"API\n"+b"x"*70000),b"calc.py":(0o100644,b"correct\n")}
        self.git.pair(self.files,{**self.files,b"calc.py":(0o100644,b"defect\n"),b"test_calc.py":(0o100644,b"regression\n")})
        self.config=replace(config.operator,role="author",participant="author")
        self.author=self.core(self.config)
        self.peer=self.core(replace(config.operator,role="reviewer",participant="peer"))
        self.author_events=[]; self.turns=[]; self.counter=0; self.evidence=[]
        self.closure={"completed":True,"exit_code":0,"root_reaped":True,"tree_retired":True}

    @staticmethod
    def core(config):
        source=GitSource(config)
        store=Store.open(config,source.repo_binding)
        return ReviewCore(config,source,store,Policy())

    def author_receipt(self,name,args,result):
        self.counter+=1
        identifier=f"call-{self.counter}"
        self.author_events.extend([
            {"type":"assistant","message":{"content":[{"type":"tool_use","id":identifier,"name":name,"input":args}]}},
            {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":identifier,"content":receipt(result)["content"]}]}}])

    async def a(self,tool,request):
        result=await getattr(self.author,tool)(request)
        assert result["ok"],result
        self.author_receipt("mcp__gauntlet_author__"+tool,{"request":request},result)
        return result

    async def p(self,tool,request):
        result=await getattr(self.peer,tool)(request)
        assert result["ok"],result
        item=McpToolCallThreadItem.model_validate({"type":"mcpToolCall","id":f"peer-{sum(len(t['items']) for t in self.turns)}",
            "server":"gauntlet-reviewer","tool":tool,"arguments":{"request":request},
            "status":"completed","error":None,"result":receipt(result)})
        self.turns[-1]["items"].append(item.model_dump(mode="json",by_alias=True))
        return result

    async def listing(self,pin,view):
        rows=[]; cursor=None
        while True:
            response=await self.p("read_review",{**bound(pin),"view":view,"cursor":cursor,"limit":1})
            rows.extend(response["result"]["items"])
            if response["result"]["complete"]:
                return rows
            cursor=response["result"]["next_cursor"]

    async def body(self,pin,artifact,view="artifact"):
        data=bytearray()
        while True:
            response=await self.p("read_review",{**bound(pin),"view":view,"artifact_id":artifact,
                "offset":len(data),"length":32768})
            page=response["result"]; data.extend(base64.b64decode(page["data_b64"]))
            if page["eof"]:
                return bytes(data)

    async def all_reads(self,pin):
        manifest=await self.listing(pin,"manifest")
        tree=await self.listing(pin,"source_tree")
        history=await self.listing(pin,"history")
        handles={row[side]["artifact_id"] for row in manifest for side in ("old_artifact","new_artifact") if row[side]}
        handles.update(row["artifact_id"] for row in tree if row["artifact_id"])
        for handle in sorted(handles):
            await self.body(pin,handle)
        for event in history:
            historical={**pin,"revision_id":event["revision_id"],"snapshot_digest":event["snapshot_digest"]}
            body=json.loads(await self.body(historical,event["artifact_id"]))
            if event["kind"]=="record_evidence":
                await self.body(historical,body["data"]["evidence_id"],"evidence")
        return manifest

    async def phase(self,number):
        pin=await self.a("open_review",{"key":f"revision-{number}","expected_version":self.author.store.read_view().store_version})
        data=b"before failure\n" if number==1 else b"after success\n"
        evidence=await self.a("record_evidence",{**bound(pin),"key":f"tests-{number}","expected_version":pin["store_version"],
            "origin":"agent_report","command":"fixture tests","runtime":"Python",
            "exit_status":1 if number==1 else 0,"content":{"kind":"inline","data_b64":base64.b64encode(data).decode()}})
        head=self.author.store.read_series().snapshot.header["source_oid"]
        self.evidence.append({"head_oid":head,"outcome":{"completed":True,"exit_code":1 if number==1 else 0,
            "root_reaped":True,"tree_retired":True,"stdout":{"prefix":base64.b64encode(data).decode(),"incomplete":False},
            "stderr":{"prefix":"","incomplete":False}}})
        self.turns.append({"id":f"turn-{number}","status":"completed","itemsView":"full","items":[]})
        rows=await self.all_reads(pin)
        before=self.author.store.read_series()
        if number==2:
            self.before={"review_id":before.id,"store_version":before.store_version,
                "findings":[{"id":f["record"]["id"],"digest":f["digest"]} for f in before.findings],
                "verdicts":before.verdict_count,"revisions":before.revision_count,"previous_thread_id":"thread-1"}
        finding={"severity":"important","location":"calc.py:1","issue":"Calculation contradicts the API","suggestion":"Apply the intended calculation"}
        verdict=await self.p("submit_review",{**bound(pin),"key":f"peer-{number}","expected_version":before.store_version,
            "verdict":"request_changes" if number==1 else "approve","summary":"Reviewed complete pinned inputs",
            "recommendations":[finding] if number==1 else [],"coverage_digest":pin["snapshot_digest"],
            "coverage":[row["change"]["change_id"] for row in rows],
            "carryover":[{"id":f["record"]["id"],"digest":f["digest"],"status":"addressed","reason":"Verified committed fix"} for f in before.findings]})
        self.author_receipt("mcp__codex_peer__codex_review",{"instance_id":"a"*32,"key":f"turn-{number}",
            "prompt":"Read complete pinned review","expected_thread_id":None if number==1 else "thread-1"},
            {"ok":True,"thread_id":"thread-1","turn_id":f"turn-{number}","text":"Recorded verdict"})
        if number==1:
            await self.a("read_review",{**bound(pin),"view":"artifact","artifact_id":verdict["result"]["event_id"],"offset":0,"length":65536})
        return pin

    async def build(self):
        self.author_receipt("mcp__codex_peer__codex_status",{},
            {"ok":True,"instance_id":"a"*32,"thread_id":None,"state":"ready"})
        await self.phase(1)
        parent=self.git.repo.refs[self.config.source_ref].decode()
        fixed=self.git.commit({**self.files,b"test_calc.py":(0o100644,b"regression\n")},parents=[parent])
        self.git.set_ref(self.config.source_ref,fixed)
        await self.phase(2)
        await self.a("review_status",{})
        return self

    def close(self):
        self.author.close(); self.peer.close(); self.git.repo.close()

    def history(self):
        return {"thread":{"id":"thread-1","turns":deepcopy(self.turns)}}

    async def verify(self,**overrides):
        args={"author_events":self.author_events,"peer_history":self.history(),
            "closure":self.closure,"evidence_runs":self.evidence}
        args.update(overrides)
        return await verify_live(self.config,**args)


@pytest.fixture
async def live(config):
    fixture=Fixture(config)
    try:
        yield await fixture.build()
    finally:
        fixture.close()


async def test_complete_receipts_and_real_core_records_pass(live):
    result=await live.verify()
    assert result["status"]=="peer_complete" and result["revisions"]==2
    assert result["turns"]==2 and result["findings"]==1
    assert result["thread_id"]=="thread-1"


@pytest.mark.parametrize("kind",["listing","range","finding"],ids=["missing-listing-page","missing-byte-range","missing-prior-finding"])
async def test_missing_read_receipts_cannot_be_replaced_by_coverage_claims(live,kind):
    history=live.history(); items=history["thread"]["turns"][-1]["items"]
    first_verdict=next(e for e in live.author.store.read_series().events if e.kind=="submit_review")
    def select(item):
        if item["tool"]!="read_review": return False
        request=item["arguments"]["request"]
        if kind=="listing": return request["view"]=="source_tree" and request.get("cursor") is not None
        if kind=="range": return request["view"]=="artifact" and request.get("offset")==32768
        return request.get("artifact_id")==first_verdict.id
    index=next(i for i,item in enumerate(items) if select(item))
    del items[index]
    with pytest.raises(AcceptanceError):
        await live.verify(peer_history=history)


@pytest.mark.parametrize("defect",["no-closure","missing-turn","other-thread","bad-evidence","no-author-receipt"])
async def test_native_or_evidence_claims_cannot_substitute_for_proof(live,defect):
    changes={}
    if defect=="no-closure": changes["closure"]={**live.closure,"tree_retired":False}
    elif defect=="missing-turn":
        history=live.history(); history["thread"]["turns"].pop(); changes["peer_history"]=history
    elif defect=="other-thread":
        history=live.history(); history["thread"]["id"]="other"; changes["peer_history"]=history
    elif defect=="bad-evidence":
        runs=deepcopy(live.evidence); runs[0]["outcome"]["stdout"]["prefix"]=base64.b64encode(b"different").decode(); changes["evidence_runs"]=runs
    else: changes["author_events"]=[]
    with pytest.raises(AcceptanceError): await live.verify(**changes)


async def test_restart_recovery_reads_every_prior_record_without_resetting_core(live):
    history={"thread":{"id":"explicit-fresh","turns":[deepcopy(live.turns[-1])]}}
    result=await verify_restart_recovery(live.config,peer_history=history,before=live.before)
    assert result["review_id"]==live.before["review_id"] and result["findings"]==1
    assert result["prior_verdicts"]==1 and result["prior_revisions"]==2


@pytest.mark.parametrize("defect",["history-page","finding-body","reset-counter","reset-review"])
async def test_restart_recovery_refuses_partial_history_or_reset_identity(live,defect):
    history={"thread":{"id":"explicit-fresh","turns":[deepcopy(live.turns[-1])]}}
    before=deepcopy(live.before)
    if defect=="reset-counter": before["verdicts"]=0
    elif defect=="reset-review": before["review_id"]="f"*32
    else:
        items=history["thread"]["turns"][0]["items"]
        prior=next(e.id for e in live.author.store.read_series().events if e.kind=="submit_review")
        index=next(i for i,item in enumerate(items) if item["tool"]=="read_review" and (
            item["arguments"]["request"].get("view")=="history" if defect=="history-page" else
            item["arguments"]["request"].get("artifact_id")==prior))
        del items[index]
    with pytest.raises(AcceptanceError):
        await verify_restart_recovery(live.config,peer_history=history,before=before)


async def test_native_submit_arguments_must_match_the_committed_request_digest(live):
    history=live.history()
    history["thread"]["turns"][0]["items"][-1]["arguments"]["request"]["summary"]="unrelated request"
    with pytest.raises(AcceptanceError):
        await live.verify(peer_history=history)


async def test_exact_core_submit_retry_is_one_canonical_verdict(live):
    history=live.history()
    for turn in history["thread"]["turns"]:
        replay=deepcopy(turn["items"][-1]); replay["id"]+="-retry"
        replay["result"]["structuredContent"]["freshness"]={"state":"not_checked"}
        replay["result"]["content"]=receipt(replay["result"]["structuredContent"])["content"]
        turn["items"].append(replay)
    assert (await live.verify(peer_history=history))["turns"]==2


@pytest.mark.parametrize("bad",[{},None,{"thread":{}}],ids=["empty","null","missing-turns"])
async def test_malformed_native_history_is_a_typed_refusal(live,bad):
    with pytest.raises(AcceptanceError) as error:
        await live.verify(peer_history=bad)
    assert error.value.code
