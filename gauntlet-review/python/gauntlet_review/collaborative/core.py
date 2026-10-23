"""Transport-independent collaborative records; native hosts own conversations."""
from __future__ import annotations

import asyncio
import base64
from dataclasses import asdict,is_dataclass
import hashlib
import json
import uuid

from .contracts import (ASSURANCE,ArtifactHandle,CoreError,Event,EvidenceData,Mutation,OpenData,
                        Policy,decode_event,encode,snapshot_from_record,validate_operator_config,
                        validate_request)
from .policy import derive_status,prepare_verdict
from .source import snapshot_payload
from .store import history_items,paginate

ROLE_TOOLS={"author":frozenset(("open_review","read_review","record_evidence","review_status")),
            "reviewer":frozenset(("read_review","record_evidence","submit_review","review_status"))}


def _wire(value):
    if is_dataclass(value):
        value=asdict(value)
    if isinstance(value,dict):
        return {key:_wire(item) for key,item in value.items()}
    if isinstance(value,(tuple,list)):
        return [_wire(item) for item in value]
    return value


class ReviewCore:
    def __init__(self,config,source,store,policy):
        self.config=validate_operator_config(config)
        self.source,self.store,self.policy=source,store,policy
        self._dependencies()

    def _dependencies(self):
        if (self.source is None or self.store is None or not isinstance(self.policy,Policy)
                or self.policy!=Policy()
                or self.source.config!=self.config or self.store.config!=self.config
                or self.source.repo_binding!=self.store.repo_binding
                or self.store.policy.digest!=self.policy.digest or self.source.policy.digest!=self.policy.digest):
            raise CoreError("CONFIGURATION_MISMATCH",detail={"reason":"core_resource_configuration"})

    def close(self):
        try:
            self.source.close()
        finally:
            self.store.close()

    @staticmethod
    async def _checkpoint():
        await asyncio.sleep(0)

    def _envelope(self,*,result=None,error=None,view=None,snapshot=None,revision_id=None,
                  review_id=None,version=None,freshness=None,snapshot_digest=None):
        series=None if view is None else view.series
        snapshot=snapshot or (None if series is None else series.snapshot)
        value={"ok":error is None,"assurance":ASSURANCE,
               "review_id":review_id or (None if series is None else series.id),
               "revision_id":revision_id or (None if series is None else series.current_revision),
               "snapshot_digest":snapshot_digest if snapshot_digest is not None else (None if snapshot is None else snapshot.digest),
               "store_version":version if version is not None else (None if view is None else view.store_version),
               "freshness":freshness or {"state":"not_checked"},"result":_wire(result) if error is None else None,
               "error":None if error is None else {"code":error.code,"retryable":error.retryable,"detail":error.detail}}
        if len(encode(value))>self.policy.mcp_result_bytes:
            raise CoreError("LIMIT_EXCEEDED",detail={"limit":"response_bytes"})
        return value

    def error_response(self,error,*,view=None,snapshot=None,revision_id=None):
        freshness=({"state":"stale",**asdict(error.observation)}
                   if error.code=="STALE" and error.observation is not None else {"state":"unknown"})
        return self._envelope(error=error,view=view,snapshot=snapshot,revision_id=revision_id,
                              freshness=freshness)

    async def open_review(self,request):
        return await self._call("open_review",request)

    async def read_review(self,request):
        return await self._call("read_review",request)

    async def record_evidence(self,request):
        return await self._call("record_evidence",request)

    async def submit_review(self,request):
        return await self._call("submit_review",request)

    async def review_status(self,request):
        return await self._call("review_status",request)

    async def _call(self,operation,payload):
        context={"view":None,"snapshot":None,"revision_id":None}
        try:
            self._dependencies()
            request=validate_request(operation,payload)
            if operation not in ROLE_TOOLS[self.config.role]:
                raise CoreError("FORBIDDEN",detail={"reason":"operation_not_permitted_for_role"})
            if operation in ("read_review","review_status"):
                def inspect(view,artifact):
                    context["view"]=view
                    if operation=="review_status":
                        return self._status(view,request)
                    snapshot=self._revision(view,request)
                    context.update(snapshot=snapshot,revision_id=request.revision_id)
                    return self._read(view,request,snapshot,artifact)
                return self.store.inspect(inspect)
            digest=hashlib.sha256(encode({"series_scope":self.config.series_scope,"operation":operation,
                "role":self.config.role,"policy_digest":self.policy.digest,"request":request.model_dump(mode="json")})).hexdigest()
            replay=self.store.lookup_retry(self.config.series_scope,self.config.participant,operation,request.key,digest)
            if replay is not None:
                return self._receipt(replay)
            candidate=None
            async def build(view):
                nonlocal candidate
                context["view"]=view
                if operation=="open_review":
                    if view.series and view.series.revision_count>=self.policy.revisions:
                        raise CoreError("LIMIT_EXCEEDED",detail={"limit":"revisions"})
                    candidate=self.source.capture(self.policy)
                    review_id=view.series.id if view.series else uuid.uuid4().hex
                    revision_id=uuid.uuid4().hex
                else:
                    self._current(view,request)
                    candidate=view.series.snapshot
                    review_id,revision_id=view.series.id,view.series.current_revision
                observation=self._fresh(candidate)
                event_id=uuid.uuid4().hex
                evidence_id=uuid.uuid4().hex if operation=="record_evidence" else None
                self._admission_ids(candidate,event_id,evidence_id,view.series)
                evidence_body=None
                if operation=="open_review":
                    data={"snapshot":{**snapshot_payload(candidate),"digest":candidate.digest},"observation":asdict(observation)}
                    result={"accepted":True,"change_count":len(candidate.changes),"manifest_digest":candidate.digest}
                elif operation=="record_evidence":
                    if request.content.kind=="inline":
                        evidence_body=base64.b64decode(request.content.data_b64,validate=True)
                        content={"kind":"inline","length":len(evidence_body),"sha256":hashlib.sha256(evidence_body).hexdigest(),
                                 "bytes_verified":True,"claims_verified":False}
                    else:
                        content={"kind":"external","uri":request.content.uri,"length":request.content.length,
                                 "sha256":request.content.sha256,"verified":False,"claims_verified":False}
                    data={"evidence_id":evidence_id,"producer":self.config.participant,"origin":request.origin,
                          "command":request.command,"runtime":request.runtime,"exit_status":request.exit_status,
                          "content":content,"observation":asdict(observation)}
                    result={"accepted":True,"evidence_id":evidence_id,"producer":self.config.participant,
                            "origin":request.origin,"content":content}
                else:
                    accepted=prepare_verdict(view.series,request,candidate)
                    round_number=view.series.verdict_count+1
                    data={"accepted_round":round_number,"reviewer":self.config.participant,
                          "requested_verdict":request.verdict,"normalized_verdict":accepted.normalized_verdict,
                          "summary":request.summary,"recommendations":list(accepted.recommendations),
                          "carryover":list(accepted.carryover),"coverage_digest":accepted.coverage_digest,
                          "coverage":request.coverage,"observation":asdict(observation)}
                    result={"accepted":True,"normalized_verdict":accepted.normalized_verdict,
                            "accepted_round":round_number,"new_finding_ids":[entry["record"]["id"] for entry in accepted.recommendations]}
                body=encode({"review_id":review_id,"revision_id":revision_id,"snapshot_digest":candidate.digest,
                             "series_scope":self.config.series_scope,"request_digest":digest,"data":data})
                event=Event(event_id,1 if view.series is None else len(view.series.events)+1,revision_id,operation,
                            body,hashlib.sha256(body).hexdigest(),view.store_version+1)
                receipt=encode({"event_id":event_id,"operation":operation,"review_id":review_id,"revision_id":revision_id,
                    "snapshot_digest":candidate.digest,"series_scope":self.config.series_scope,"request_digest":digest,
                    "store_version":view.store_version+1,"observation":asdict(observation),"result":result})
                return Mutation(event,evidence_body,receipt)
            async def checkpoint():
                await self._checkpoint()
                if candidate is not None:
                    self._matches(candidate,self.source.observe())
            committed=await self.store.mutate(self.config.series_scope,self.config.participant,operation,request.key,
                                               digest,request.expected_version,build,checkpoint)
            return self._receipt(committed)
        except CoreError as error:
            return self.error_response(error,**context)
        except Exception:
            return self.error_response(CoreError("INTERNAL_ERROR",detail={"correlation_id":uuid.uuid4().hex}),**context)

    def _receipt(self,stored):
        receipt=json.loads(stored.result_bytes)
        freshness={"state":"not_checked"} if stored.replayed else {"state":"match",**receipt["observation"]}
        return self._envelope(result={**receipt["result"],"event_id":receipt["event_id"],
                                     "original_observation":receipt["observation"]},snapshot_digest=receipt["snapshot_digest"],
                              review_id=receipt["review_id"],revision_id=receipt["revision_id"],
                              version=stored.store_version,freshness=freshness)

    @staticmethod
    def _current(view,request):
        series=view.series
        if series is None or request.review_id!=series.id:
            raise CoreError("NOT_FOUND",detail={"reason":"review"})
        if request.revision_id!=series.current_revision or request.snapshot_digest!=series.snapshot.digest:
            raise CoreError("STALE",detail={"reason":"current_revision_required"})

    @staticmethod
    def _matches(snapshot,observation):
        if observation.source_oid!=snapshot.header["source_oid"] or observation.target_oid!=snapshot.header["target_oid"]:
            raise CoreError("STALE",detail={"reason":"configured_refs_changed"},observation=observation)

    def _fresh(self,snapshot):
        observation=self.source.check_snapshot(snapshot)
        self._matches(snapshot,observation)
        return observation

    def _blob_space(self,snapshot):
        identities={}
        def add(identifier,side,path,oid):
            material=(side,path,oid)
            if identifier in identities and identities[identifier]!=material:
                raise CoreError("DIGEST_MISMATCH",detail={"reason":"artifact_id_collision"})
            identities[identifier]=material
        for row in self.source.manifest_rows(snapshot):
            for field,handle in (("old",row.old_artifact),("new",row.new_artifact)):
                if handle:
                    add(handle.artifact_id,handle.side,getattr(row.change,field+"_path_b64"),handle.oid)
        for entry in self.source.source_inventory(snapshot):
            if entry.artifact_id:
                add(entry.artifact_id,"head",entry.raw_path_b64,entry.oid)
        return identities

    def _admission_ids(self,snapshot,event_id,evidence_id,history):
        reserved=set(self._blob_space(snapshot))
        if history:
            for event in history.events:
                reserved.add(event.id)
                if event.kind=="record_evidence":
                    reserved.add(EvidenceData.model_validate(decode_event(event).data,strict=True).evidence_id)
        if event_id in reserved or (evidence_id is not None and (evidence_id in reserved or evidence_id==event_id)):
            raise CoreError("DIGEST_MISMATCH",detail={"reason":"record_artifact_id_collision"})

    def _status(self,view,request):
        series=view.series
        if request.review_id is not None and (series is None or request.review_id!=series.id):
            raise CoreError("NOT_FOUND",detail={"reason":"review"})
        if series is None:
            return self._envelope(view=view,result={"series":None,"status":None,"finding_rollups":[],
                                                  "counts":{"findings":0,"verdicts":0,"revisions":0,"evidence_bytes":0,"evidence_records":0}})
        observation=self.source.check_snapshot(series.snapshot)
        status=derive_status(series,observation)
        return self._envelope(view=view,result=asdict(status),freshness=status.freshness)

    @staticmethod
    def _revision(view,request):
        if view.series is None or request.review_id!=view.series.id:
            raise CoreError("NOT_FOUND",detail={"reason":"review"})
        for event in view.series.events:
            if event.kind=="open_review" and event.revision_id==request.revision_id:
                snapshot=snapshot_from_record(OpenData.model_validate(decode_event(event).data,strict=True).snapshot.model_dump(mode="json"))
                if snapshot.digest!=request.snapshot_digest:
                    raise CoreError("STALE",detail={"reason":"snapshot_pin"})
                return snapshot
        raise CoreError("NOT_FOUND",detail={"reason":"revision"})

    def _read(self,view,request,snapshot,artifact):
        if request.view in ("history","manifest","source_tree"):
            mapper=None
            if request.view=="history":
                rows=history_items(view.series)
            elif request.view=="manifest":
                rows=tuple(asdict(row) for row in self.source.manifest_rows(snapshot))
            else:
                rows=self.source.source_inventory(snapshot)
                mapper=lambda entry:asdict(self.source.describe_entry(snapshot,entry))
            page=paginate(rows,binding={"review_id":request.review_id,"revision_id":request.revision_id,
                "snapshot_digest":request.snapshot_digest,"view":request.view,"store_version":view.store_version},
                cursor=request.cursor,limit=request.limit,mapper=mapper)
            response=self._envelope(view=view,snapshot=snapshot,revision_id=request.revision_id,
                result={"items":page.items,"next_cursor":page.next_cursor,"complete":page.complete})
            if len(encode(response))>self.policy.listing_bytes:
                raise CoreError("LIMIT_EXCEEDED",detail={"limit":"listing_response_bytes"})
            return response
        kind="evidence" if request.view=="evidence" else "event"
        handle=None
        if request.view=="evidence":
            page=artifact(request.review_id,request.revision_id,request.artifact_id,request.offset,request.length,evidence=True)
        else:
            for row in self.source.manifest_rows(snapshot):
                for candidate in (row.old_artifact,row.new_artifact):
                    if candidate and candidate.artifact_id==request.artifact_id:
                        if handle is not None and candidate!=handle:
                            raise CoreError("DIGEST_MISMATCH",detail={"reason":"artifact_id_collision"})
                        handle=candidate
            stored=any(event.id==request.artifact_id and event.revision_id==request.revision_id for event in view.series.events)
            if stored:
                if handle:
                    raise CoreError("DIGEST_MISMATCH",detail={"reason":"artifact_id_collision"})
                page=artifact(request.review_id,request.revision_id,request.artifact_id,request.offset,request.length)
            else:
                if handle is None:
                    for entry in self.source.source_inventory(snapshot):
                        if entry.artifact_id==request.artifact_id:
                            entry=self.source.describe_entry(snapshot,entry)
                            handle=ArtifactHandle(entry.artifact_id,"blob","head",entry.length,entry.digest,entry.mode,entry.oid)
                            break
                if handle is None:
                    raise CoreError("NOT_FOUND",detail={"reason":"artifact"})
                kind="blob"
                page=self.source.read_blob(handle.oid,request.offset,request.length,handle.sha256)
                if page.total!=handle.byte_length:
                    raise CoreError("DIGEST_MISMATCH",detail={"reason":"blob_length"})
        result={"artifact_id":request.artifact_id,"kind":kind,"encoding":"base64",
                "data_b64":base64.b64encode(page.data).decode("ascii"),"offset":page.offset,
                "length":len(page.data),"total":page.total,"eof":page.eof,"sha256":page.digest}
        response=self._envelope(view=view,snapshot=snapshot,revision_id=request.revision_id,result=result)
        metadata={**response,"result":{key:value for key,value in result.items() if key!="data_b64"}}
        if len(encode(metadata))>self.policy.binary_metadata_bytes:
            raise CoreError("LIMIT_EXCEEDED",detail={"limit":"binary_metadata_bytes"})
        return response
