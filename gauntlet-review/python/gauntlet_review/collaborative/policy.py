"""Deterministic projection of validated collaborative events."""
from .contracts import (CoreError,EvidenceData,OpenData,SeriesView,decode_event,
                        snapshot_from_record)
from pydantic import ValidationError


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
            else:
                raise CoreError("CORRUPT_STATE",detail={"reason":"unknown_event_kind"})
        except (ValidationError,ValueError,TypeError) as error:
            raise CoreError("CORRUPT_STATE",detail={"reason":"event_data_shape"}) from error
    return SeriesView(review_id,last_version,revision,snapshot,tuple(events),(),0,len(revisions))
