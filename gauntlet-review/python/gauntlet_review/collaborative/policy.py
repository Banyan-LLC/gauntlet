"""Finding continuity, complete coverage and observed collaborative status."""
import hashlib

from gauntlet_review.verdict import recommendation_id

from .contracts import (AcceptedVerdict,CoreError,EvidenceData,FindingEnvelope,OpenData,
                        Policy,SeriesView,Status,VerdictData,decode_event,encode,
                        snapshot_from_record,validate_request,verdict_capacity)
from pydantic import ValidationError


def prepare_verdict(history,request,snapshot):
    request=validate_request("submit_review",request)
    policy=Policy()
    if history.id!=request.review_id:
        raise CoreError("NOT_FOUND",detail={"reason":"review"})
    if request.revision_id!=history.current_revision or request.snapshot_digest!=snapshot.digest or snapshot!=history.snapshot:
        raise CoreError("STALE",detail={"reason":"revision_or_snapshot"})
    candidate_count=len(history.findings)+len(request.recommendations)
    if candidate_count>policy.findings:
        raise CoreError("LIMIT_EXCEEDED",detail={"limit":"findings"})
    if history.verdict_count>=policy.verdicts:
        raise CoreError("LIMIT_EXCEEDED",detail={"limit":"verdicts"})
    if verdict_capacity(candidate_count)>policy.verdict_bytes:
        raise CoreError("LIMIT_EXCEEDED",detail={"limit":"future_carryover_bytes"})
    if request.coverage_digest!=snapshot.digest or set(request.coverage)!={change.change_id for change in snapshot.changes}:
        raise CoreError("INVALID_ARGUMENT",detail={"reason":"complete_coverage_required"})
    expected={}
    for finding in history.findings:
        try:
            envelope=FindingEnvelope.model_validate({"record":finding["record"],"digest":finding["digest"]},strict=True)
            record=envelope.record.model_dump(mode="json")
            rec={key:record[key] for key in ("severity","location","issue","suggestion")}
            if (record["review_id"]!=history.id or record["id"] in expected
                    or record["id"]!=recommendation_id(record["round"],record["index"],rec)
                    or hashlib.sha256(encode(record)).hexdigest()!=envelope.digest):
                raise ValueError("prior finding identity")
            expected[record["id"]]=envelope
        except (ValueError,TypeError,KeyError,ValidationError) as error:
            raise CoreError("CORRUPT_STATE",detail={"reason":"prior_finding_record"}) from error
    if {entry.id for entry in request.carryover}!=set(expected):
        raise CoreError("INVALID_ARGUMENT",detail={"reason":"complete_carryover_required"})
    unresolved=False
    for entry in request.carryover:
        finding=expected[entry.id]
        if entry.digest!=finding.digest:
            raise CoreError("DIGEST_MISMATCH",detail={"reason":"carryover_record"})
        unresolved|=finding.record.severity!="nit" and entry.status!="addressed"
    round_number=history.verdict_count+1
    recommendations=[]
    new_non_nit=False
    ids=set(expected)
    for index,recommendation in enumerate(request.recommendations):
        rec=recommendation.model_dump(mode="json")
        identifier=recommendation_id(round_number,index,rec)
        if identifier in ids:
            raise CoreError("DIGEST_MISMATCH",detail={"reason":"finding_id_collision"})
        ids.add(identifier)
        record={**rec,"id":identifier,"review_id":history.id,"revision_id":request.revision_id,
                "round":round_number,"index":index}
        recommendations.append({"record":record,"digest":hashlib.sha256(encode(record)).hexdigest()})
        new_non_nit|=recommendation.severity!="nit"
    normalized="request_changes" if request.verdict=="approve" and new_non_nit else request.verdict
    # This internal receipt classification is never a current completion result.
    receipt_status="changes_requested" if normalized=="request_changes" or unresolved else "approval_recorded"
    return AcceptedVerdict(normalized,tuple(recommendations),
        tuple(entry.model_dump(mode="json") for entry in request.carryover),request.coverage_digest,receipt_status)


def reduce_series(events):
    """Rebuild projections; storage counters are supplied separately by Store."""
    if not events:
        raise CoreError("CORRUPT_STATE",detail={"reason":"series_has_no_revision"})
    review_id=None
    revision=None
    snapshot=None
    revisions=set()
    last_version=0
    evidence_ids=set()
    findings=[]
    verdict_count=0
    prior_events=[]
    for sequence,event in enumerate(events,1):
        body=decode_event(event)
        if event.seq!=sequence or type(event.store_version) is not int or event.store_version<=last_version:
            raise CoreError("CORRUPT_STATE",detail={"reason":"event_order"})
        last_version=event.store_version
        if review_id is None:
            review_id=body.review_id
        if body.review_id!=review_id or event.revision_id!=body.revision_id:
            raise CoreError("CORRUPT_STATE",detail={"reason":"event_ownership"})
        try:
            if event.kind=="open_review":
                data=OpenData.model_validate(body.data,strict=True)
                if body.revision_id in revisions or len(revisions)>=20:
                    raise CoreError("CORRUPT_STATE",detail={"reason":"revision_identity_or_limit"})
                snapshot=snapshot_from_record(data.snapshot.model_dump(mode="json"))
                if snapshot.digest!=body.snapshot_digest:
                    raise CoreError("CORRUPT_STATE",detail={"reason":"revision_snapshot"})
                revisions.add(body.revision_id)
                revision=body.revision_id
            elif event.kind=="record_evidence":
                if body.revision_id!=revision or snapshot is None or body.snapshot_digest!=snapshot.digest:
                    raise CoreError("CORRUPT_STATE",detail={"reason":"evidence_revision"})
                data=EvidenceData.model_validate(body.data,strict=True)
                if data.evidence_id in evidence_ids:
                    raise CoreError("CORRUPT_STATE",detail={"reason":"duplicate_evidence"})
                evidence_ids.add(data.evidence_id)
            elif event.kind=="submit_review":
                if body.revision_id!=revision or snapshot is None or body.snapshot_digest!=snapshot.digest:
                    raise CoreError("CORRUPT_STATE",detail={"reason":"verdict_revision"})
                data=VerdictData.model_validate(body.data,strict=True)
                prior=SeriesView(review_id,event.store_version-1,revision,snapshot,tuple(prior_events),
                                 tuple(findings),verdict_count,len(revisions))
                raw={"key":"stored_validation","expected_version":event.store_version-1,
                     "review_id":review_id,"revision_id":revision,"snapshot_digest":snapshot.digest,
                     "verdict":data.requested_verdict,"summary":data.summary,
                     "recommendations":[{key:entry.record.model_dump(mode="json")[key]
                        for key in ("severity","location","issue","suggestion")} for entry in data.recommendations],
                     "coverage_digest":data.coverage_digest,"coverage":data.coverage,
                     "carryover":[entry.model_dump(mode="json") for entry in data.carryover]}
                try:
                    accepted=prepare_verdict(prior,raw,snapshot)
                except CoreError as error:
                    raise CoreError("CORRUPT_STATE",detail={"reason":"stored_verdict_policy"}) from error
                if (data.accepted_round!=verdict_count+1 or data.normalized_verdict!=accepted.normalized_verdict
                        or [entry.model_dump(mode="json") for entry in data.recommendations]!=list(accepted.recommendations)):
                    raise CoreError("CORRUPT_STATE",detail={"reason":"stored_finding_identity"})
                dispositions={entry["id"]:entry["status"] for entry in accepted.carryover}
                findings=[{**finding,"disposition":dispositions[finding["record"]["id"]]} for finding in findings]
                findings.extend({**finding,"disposition":"outstanding","event_id":event.id,
                                 "snapshot_digest":snapshot.digest} for finding in accepted.recommendations)
                verdict_count+=1
            else:
                raise CoreError("CORRUPT_STATE",detail={"reason":"unknown_event_kind"})
        except (ValidationError,ValueError,TypeError) as error:
            raise CoreError("CORRUPT_STATE",detail={"reason":"event_data_shape"}) from error
        prior_events.append(event)
    return SeriesView(review_id,last_version,revision,snapshot,tuple(events),tuple(findings),verdict_count,len(revisions))


def derive_status(history,observation):
    snapshot=history.snapshot
    fresh=(observation.source_oid==snapshot.header["source_oid"] and
           observation.target_oid==snapshot.header["target_oid"])
    latest=None
    for event in reversed(history.events):
        if event.revision_id==history.current_revision and event.kind=="submit_review":
            latest=VerdictData.model_validate(decode_event(event).data,strict=True)
            break
    unresolved=sum(finding["record"]["severity"]!="nit" and finding["disposition"]!="addressed"
                   for finding in history.findings)
    if not fresh:
        state="stale"
    elif latest is None:
        state="awaiting_review"
    elif latest.normalized_verdict=="request_changes" or unresolved:
        state="changes_requested"
    else:
        state="peer_complete"
    rollups=tuple({"id":finding["record"]["id"],"severity":finding["record"]["severity"],
                   "disposition":finding["disposition"],"digest":finding["digest"],
                   "record":{"artifact_id":finding["event_id"],"revision_id":finding["record"]["revision_id"],
                             "snapshot_digest":finding["snapshot_digest"],"index":finding["record"]["index"]}}
                  for finding in history.findings)
    return Status({"id":history.id,"current_revision":history.current_revision},state,rollups,
                  {"findings":len(rollups),"unresolved_non_nits":unresolved,"verdicts":history.verdict_count,
                   "revisions":history.revision_count,"evidence_bytes":history.evidence_bytes,
                   "evidence_records":sum(event.kind=="record_evidence" for event in history.events)},snapshot.digest,
                  {"state":"match" if fresh else "stale","source_oid":observation.source_oid,
                   "target_oid":observation.target_oid,"checked_at":observation.checked_at})
