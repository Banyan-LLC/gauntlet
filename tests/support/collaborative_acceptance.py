"""Independent test-only acceptance of actual native receipts and canonical state.

No model is called here. Coverage prose, model output and stored execution claims
are insufficient: complete linked reads and original native outcomes are needed.
"""
from __future__ import annotations

import base64
from contextlib import contextmanager
from dataclasses import asdict,dataclass
from functools import wraps
import hashlib
import json

from gauntlet_review.collaborative.contracts import Policy,encode,snapshot_from_record,validate_request
from gauntlet_review.collaborative.core import ReviewCore
from gauntlet_review.collaborative.policy import reduce_series
from gauntlet_review.collaborative.source import GitSource
from gauntlet_review.collaborative.store import Store,history_items


class AcceptanceError(Exception):
    def __init__(self,code):
        self.code=code
        super().__init__(code)


def need(condition,code):
    if not condition:
        raise AcceptanceError(code)


def verified(function):
    @wraps(function)
    async def inspect(*args,**kwargs):
        try:
            return await function(*args,**kwargs)
        except AcceptanceError:
            raise
        except Exception as error:
            raise AcceptanceError("UNVERIFIED_ACCEPTANCE_INPUT") from error
    return inspect


def _payload(value,depth=0):
    need(depth<6,"INVALID_TOOL_RECEIPT")
    if isinstance(value,str):
        try:
            return _payload(json.loads(value),depth+1)
        except (ValueError,TypeError) as error:
            raise AcceptanceError("INVALID_TOOL_RECEIPT") from error
    if isinstance(value,list):
        text=[item["text"] for item in value if isinstance(item,dict) and item.get("type")=="text"]
        need(len(text)==1,"INVALID_TOOL_RECEIPT")
        return _payload(text[0],depth+1)
    need(type(value) is dict,"INVALID_TOOL_RECEIPT")
    if type(value.get("ok")) is bool:
        return value
    structured=value.get("structuredContent")
    if structured is not None:
        result=_payload(structured,depth+1)
        if value.get("content"):
            need(_payload(value["content"],depth+1)==result,"MISMATCHED_TOOL_COPIES")
        return result
    need("content" in value,"INVALID_TOOL_RECEIPT")
    return _payload(value["content"],depth+1)


@dataclass
class Call:
    tool:str
    arguments:dict
    response:dict


def author_calls(events):
    pending={}; finished=set(); calls=[]
    for event in events:
        content=event.get("message",{}).get("content",[])
        if not isinstance(content,list):
            continue
        for item in content:
            if not isinstance(item,dict):
                continue
            if item.get("type")=="tool_use":
                identifier=item["id"]
                if identifier in pending:
                    need(pending[identifier]==item,"CONFLICTING_TOOL_ID")
                pending[identifier]=item
            elif item.get("type")=="tool_result" and item.get("tool_use_id") in pending:
                identifier=item["tool_use_id"]
                if identifier in finished:
                    continue
                finished.add(identifier)
                use=pending[identifier]
                if not use["name"].startswith("mcp__") or item.get("is_error"):
                    continue
                calls.append(Call(use["name"],use["input"],_payload(item["content"])))
    return calls


def peer_calls(turn):
    need(turn.get("status")=="completed" and turn.get("itemsView")=="full","INCOMPLETE_PEER_TURN")
    calls=[]
    for item in turn["items"]:
        if item.get("type")!="mcpToolCall" or item.get("server")!="gauntlet-reviewer":
            continue
        if item.get("status")!="completed" or item.get("error") is not None:
            continue
        arguments=item["arguments"]
        if isinstance(arguments,str):
            arguments=json.loads(arguments)
        calls.append(Call(item["tool"],arguments,_payload(item["result"])))
    return calls


def _request(call):
    value=call.arguments.get("request")
    need(type(value) is dict,"INVALID_CORE_ARGUMENTS")
    return value


def _bound(body):
    return {key:body[key] for key in ("review_id","revision_id","snapshot_digest")}


def _same_pin(value,pin):
    return all(value.get(key)==expected for key,expected in pin.items())


def _listing(calls,pin,view,expected,version):
    selected=[]
    for call in calls:
        if call.tool!="read_review" or call.response.get("ok") is not True:
            continue
        request=_request(call)
        if request.get("view")==view and _same_pin(request,pin) and call.response.get("store_version")==version:
            need(_same_pin(call.response,pin),"READ_PIN_MISMATCH")
            selected.append(call)
    cursor=None; rows=[]; seen=set()
    while True:
        candidates=[call for call in selected if _request(call).get("cursor")==cursor]
        need(candidates,"MISSING_LISTING_PAGE")
        page=candidates[0].response["result"]
        need(all(call.response["result"]==page for call in candidates),"CONFLICTING_LISTING_PAGE")
        rows.extend(page["items"])
        if page["complete"] is True:
            need(page["next_cursor"] is None and rows==list(expected),"INCOMPLETE_LISTING")
            return rows
        next_cursor=page["next_cursor"]
        need(page["items"] and isinstance(next_cursor,str) and next_cursor not in seen,"INVALID_LISTING_CHAIN")
        seen.add(next_cursor); cursor=next_cursor


def _bytes(calls,pin,artifact,expected,view="artifact",kind=None):
    pages={}; digest=hashlib.sha256(expected).hexdigest()
    for call in calls:
        if call.tool!="read_review" or call.response.get("ok") is not True:
            continue
        request=_request(call)
        if request.get("view")!=view or request.get("artifact_id")!=artifact or not _same_pin(request,pin):
            continue
        need(_same_pin(call.response,pin),"READ_PIN_MISMATCH")
        page=call.response["result"]
        try:
            data=base64.b64decode(page["data_b64"],validate=True)
        except (ValueError,TypeError) as error:
            raise AcceptanceError("INVALID_READ_BYTES") from error
        offset=request.get("offset",0)
        need(type(offset) is int and offset>=0,"INVALID_READ_RANGE")
        need(page["artifact_id"]==artifact and page["encoding"]=="base64" and page["offset"]==offset
            and page["length"]==len(data) and len(data)<=request.get("length",65536)
            and page["total"]==len(expected) and page["sha256"]==digest
            and offset+len(data)<=len(expected) and data==expected[offset:offset+len(data)]
            and page["eof"] is (offset+len(data)==len(expected))
            and (kind is None or page["kind"]==kind),"READ_BYTES_MISMATCH")
        if offset in pages:
            need(pages[offset]==(data,page["eof"]),"CONFLICTING_READ_RANGE")
        pages[offset]=(data,page["eof"])
    offset=0
    while True:
        need(offset in pages,"MISSING_READ_RANGE")
        data,eof=pages[offset]
        offset+=len(data)
        if eof:
            need(offset==len(expected),"INCOMPLETE_READ")
            return
        need(data,"NONPROGRESSING_READ")


def _source_bytes(source,handle):
    output=bytearray()
    while True:
        page=source.read_blob(handle["oid"],len(output),65536,handle["sha256"])
        output.extend(page.data)
        if page.eof:
            need(len(output)==handle["byte_length"],"CANONICAL_SOURCE_LENGTH")
            return bytes(output)


def _evidence_bytes(store,pin,identifier):
    output=bytearray()
    while True:
        page=store.read_artifact(pin["review_id"],pin["revision_id"],identifier,len(output),65536,evidence=True)
        output.extend(page.data)
        if page.eof:
            return bytes(output)


@contextmanager
def _core(config):
    with GitSource(config) as source,Store.open(config,source.repo_binding) as store:
        yield ReviewCore(config,source,store,Policy())


def _matching_submit(calls,events):
    by_id={event.id:event for event in events if event.kind=="submit_review"}
    matches=[]
    for index,call in enumerate(calls):
        if call.tool!="submit_review" or call.response.get("ok") is not True:
            continue
        event=by_id.get(call.response["result"].get("event_id"))
        need(event is not None,"UNBOUND_VERDICT_RECEIPT")
        body=json.loads(event.body); request=_request(call)
        validated=validate_request("submit_review",request)
        digest=hashlib.sha256(encode({"series_scope":body["series_scope"],"operation":"submit_review",
            "role":"reviewer","policy_digest":Policy().digest,"request":validated.model_dump(mode="json")})).hexdigest()
        need(_same_pin(request,_bound(body)) and _same_pin(call.response,_bound(body))
            and digest==body["request_digest"]
            and call.response["store_version"]==event.store_version
            and request["coverage_digest"]==body["data"]["coverage_digest"]
            and request["coverage"]==body["data"]["coverage"]
            and request["carryover"]==body["data"]["carryover"],"VERDICT_RECEIPT_MISMATCH")
        matches.append((index,event))
    need(matches and len({event.id for _,event in matches})==1,"ONE_VERDICT_PER_TURN_REQUIRED")
    return matches[0]


def _reads(core,calls,event):
    body=json.loads(event.body); pin=_bound(body)
    all_events=core.store.read_series().events
    prefix=tuple(prior for prior in all_events if prior.store_version<event.store_version)
    need(prefix,"MISSING_PRIOR_STATE")
    prior=reduce_series(prefix)
    opened=next(e for e in prefix if e.kind=="open_review" and e.revision_id==event.revision_id)
    snapshot=snapshot_from_record(json.loads(opened.body)["data"]["snapshot"])
    manifest=[asdict(row) for row in core.source.manifest_rows(snapshot)]
    tree=[asdict(core.source.describe_entry(snapshot,entry)) for entry in core.source.source_inventory(snapshot)]
    # A single complete history chain establishes one pre-verdict store version.
    versions={call.response.get("store_version") for call in calls if call.tool=="read_review"
        and call.response.get("ok") is True and _request(call).get("view")=="history"
        and _same_pin(_request(call),pin)}
    verified=None
    for version in sorted(versions,reverse=True):
        if type(version) is not int or version>=event.store_version:
            continue
        earlier=tuple(e for e in prefix if e.store_version<=version)
        if len(earlier)!=len(prefix):
            continue
        try:
            _listing(calls,pin,"history",history_items(prior),version)
            _listing(calls,pin,"manifest",manifest,version)
            _listing(calls,pin,"source_tree",tree,version)
            verified=version
            break
        except AcceptanceError:
            continue
    need(verified is not None,"MISSING_COMPLETE_LISTINGS")
    handles={}
    for row in manifest:
        for side in ("old_artifact","new_artifact"):
            if row[side]:
                handles[row[side]["artifact_id"]]=row[side]
    for row in tree:
        if row["artifact_id"]:
            handles[row["artifact_id"]]={"oid":row["oid"],"sha256":row["digest"],"byte_length":row["length"]}
    for identifier,handle in handles.items():
        _bytes(calls,pin,identifier,_source_bytes(core.source,handle),kind="blob")
    for previous in prefix:
        previous_body=json.loads(previous.body); historical=_bound(previous_body)
        _bytes(calls,historical,previous.id,previous.body,kind="event")
        if previous.kind=="record_evidence":
            identifier=previous_body["data"]["evidence_id"]
            need(previous_body["data"]["content"]["kind"]=="inline","INLINE_EVIDENCE_REQUIRED")
            _bytes(calls,historical,identifier,_evidence_bytes(core.store,historical,identifier),"evidence","evidence")
    return prior


def _native(outcome,expected_exit=0):
    need(outcome.get("completed") is True and outcome.get("exit_code")==expected_exit
        and outcome.get("root_reaped") is True and outcome.get("tree_retired") is True,"INCOMPLETE_NATIVE_RUN")


@verified
async def verify_live(config,*,author_events,peer_history,closure,evidence_runs):
    _native(closure)
    author=author_calls(author_events)
    successful=[call for call in author if call.response.get("ok") is True]
    bridges=[call for call in successful if call.tool=="mcp__codex_peer__codex_review"]
    # Exact retries may appear again; they do not constitute another native turn.
    unique={}
    for call in bridges:
        identity=(call.response.get("thread_id"),call.response.get("turn_id"))
        if identity in unique:
            need(unique[identity].response==call.response and unique[identity].arguments==call.arguments,"CONFLICTING_BRIDGE_REPLAY")
        unique[identity]=call
    bridges=list(unique.values())
    need(len(bridges)>=2,"MISSING_BRIDGE_TURNS")
    thread=peer_history["thread"]
    need(all(call.response["thread_id"]==thread["id"] for call in bridges),"THREAD_MISMATCH")
    statuses=[call.response for call in successful if call.tool=="mcp__codex_peer__codex_status"]
    need(statuses and statuses[0]["state"]=="ready" and statuses[0]["thread_id"] is None,"MISSING_INSTANCE_RECEIPT")
    for number,call in enumerate(bridges):
        need(call.arguments.get("instance_id")==statuses[0]["instance_id"] and
            call.arguments.get("expected_thread_id")== (None if number==0 else thread["id"]),"BRIDGE_OWNERSHIP_MISMATCH")
    turns={turn["id"]:turn for turn in thread["turns"]}
    need(len(turns)==len(thread["turns"]),"DUPLICATE_TURN")
    with _core(config) as core:
        series=core.store.read_series()
        need(series is not None,"MISSING_CANONICAL_STATE")
        opens=[event for event in series.events if event.kind=="open_review"]
        verdicts=[event for event in series.events if event.kind=="submit_review"]
        need(len(opens)>=2 and len(verdicts)==len(bridges),"MISSING_REVISIONS_OR_VERDICTS")
        source_oids=[json.loads(event.body)["data"]["snapshot"]["header"]["source_oid"] for event in opens]
        need(len(set(source_oids))==len(source_oids),"UNCOMMITTED_FIX")
        bound_verdicts=[]
        for bridge in bridges:
            need(bridge.response["turn_id"] in turns,"MISSING_PEER_TURN")
            calls=peer_calls(turns[bridge.response["turn_id"]])
            index,event=_matching_submit(calls,series.events)
            _reads(core,calls[:index],event)
            bound_verdicts.append(event)
        need([event.id for event in bound_verdicts]==[event.id for event in verdicts],"VERDICT_ORDER_MISMATCH")
        first=json.loads(verdicts[0].body)
        findings=first["data"]["recommendations"]
        need(any(finding["record"]["severity"]!="nit" for finding in findings),"MISSING_REAL_FINDING")
        last=json.loads(verdicts[-1].body)
        need(first["revision_id"]!=last["revision_id"] and last["data"]["normalized_verdict"]=="approve","MISSING_FIX_CLOSURE")
        dispositions={entry["id"]:entry for entry in last["data"]["carryover"]}
        for finding in series.findings:
            entry=dispositions.get(finding["record"]["id"])
            need(entry is not None and entry["digest"]==finding["digest"] and entry["status"]=="addressed","UNRESOLVED_FINDING")
        author_core=[Call(call.tool.removeprefix("mcp__gauntlet_author__"),call.arguments,call.response)
            for call in successful if call.tool.startswith("mcp__gauntlet_author__")]
        for event in series.events:
            if event.kind in ("open_review","record_evidence"):
                need(any(call.tool==event.kind and call.response.get("result",{}).get("event_id")==event.id
                    for call in author_core),"MISSING_AUTHOR_RECEIPT")
        # The author must read the original persisted finding body, not infer it
        # from a peer's prose. Native peer complete history is checked above.
        _bytes(author_core,_bound(first),verdicts[0].id,verdicts[0].body,kind="event")
        evidence=[event for event in series.events if event.kind=="record_evidence"]
        need(len(evidence)>=2,"MISSING_EXECUTION_EVIDENCE")
        by_revision={event.revision_id:json.loads(event.body)["data"]["snapshot"]["header"]["source_oid"] for event in opens}
        for event in evidence:
            body=json.loads(event.body); pin=_bound(body); data=body["data"]
            raw=_evidence_bytes(core.store,pin,data["evidence_id"])
            candidates=[run["outcome"] for run in evidence_runs if run["head_oid"]==by_revision[event.revision_id]]
            matched=False
            for outcome in candidates:
                _native(outcome,data["exit_status"])
                need(not outcome["stdout"]["incomplete"] and not outcome["stderr"]["incomplete"],"PARTIAL_NATIVE_EVIDENCE")
                original=base64.b64decode(outcome["stdout"]["prefix"],validate=True)+base64.b64decode(outcome["stderr"]["prefix"],validate=True)
                if raw==original:
                    matched=True
            need(matched,"EXECUTION_EVIDENCE_MISMATCH")
        fresh=await core.review_status({})
        need(fresh["ok"] and fresh["freshness"]["state"]=="match" and fresh["result"]["status"]=="peer_complete","NOT_FRESH_COMPLETE")
        need(any(call.tool=="review_status" and call.response.get("freshness",{}).get("state")=="match"
            and call.response.get("result",{}).get("status")=="peer_complete" for call in author_core),"MISSING_AUTHOR_FRESH_STATUS")
        return {"status":"peer_complete","review_id":series.id,"thread_id":thread["id"],
            "turns":len(bridges),"revisions":len(opens),"findings":len(series.findings),"source_oids":source_oids}


@verified
async def verify_restart_recovery(config,*,peer_history,before):
    thread=peer_history["thread"]
    need(thread["id"]!=before["previous_thread_id"] and len(thread["turns"])==1,"NOT_EXPLICIT_FRESH_CONVERSATION")
    with _core(config) as core:
        series=core.store.read_series()
        calls=peer_calls(thread["turns"][0])
        index,event=_matching_submit(calls,series.events)
        prior=_reads(core,calls[:index],event)
        findings=[{"id":f["record"]["id"],"digest":f["digest"]} for f in prior.findings]
        need(prior.id==before["review_id"] and prior.store_version==before["store_version"]
            and prior.verdict_count==before["verdicts"] and prior.revision_count==before["revisions"]
            and findings==before["findings"],"RESTART_RESET_STATE")
        return {"review_id":prior.id,"findings":len(findings),"prior_verdicts":prior.verdict_count,"prior_revisions":prior.revision_count}
