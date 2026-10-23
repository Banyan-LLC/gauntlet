"""Observable controls for the approved manifest binding and finding namespace."""
from dataclasses import replace
import hashlib

import pytest

from gauntlet_review.collaborative.contracts import CoreError,encode


@pytest.mark.anyio
async def test_complete_manifest_attestation_is_bound_to_its_snapshot_header(flow):
    opened=await flow.open()
    manifest=await flow.listing(opened,'manifest',limit=1)
    snapshot=flow.author.store.read_series().snapshot
    payload={'header':dict(snapshot.header),'changes':[row['change'] for row in manifest]}
    digest=hashlib.sha256(encode(payload)).hexdigest()
    assert opened['result']['manifest_digest']==opened['snapshot_digest']==digest
    request=await flow.verdict_request()
    # A detached change-list hash cannot attest the pinned refs/policy, and an
    # altered complete manifest cannot attest this snapshot either.
    detached=hashlib.sha256(encode(payload['changes'])).hexdigest()
    changed={**payload,'changes':[]}
    altered=hashlib.sha256(encode(changed)).hexdigest()
    for unrelated in (detached,altered):
        response=await flow.reviewer.submit_review({**request,'coverage_digest':unrelated})
        assert not response['ok'] and response['error']['code']=='INVALID_ARGUMENT'
        assert flow.author.store.version()==1
    accepted=await flow.reviewer.submit_review(request)
    assert accepted['ok'] and accepted['result']['normalized_verdict']=='approve'


@pytest.mark.anyio
async def test_same_legacy_id_in_two_reviews_cannot_alias_findings_or_carryover(store,append_event,append_verdict,verdict_factory):
    from gauntlet_review.collaborative.policy import prepare_verdict
    from gauntlet_review.collaborative.store import Store
    recommendation={'severity':'important','location':'file:1','issue':'same issue','suggestion':'same fix'}
    await append_event(store)
    await append_verdict(store,recommendations=[recommendation])
    with Store.open(replace(store.config,repository_id='other_review'),store.repo_binding) as other:
        await append_event(other,expected_version=2)
        await append_verdict(other,recommendations=[recommendation])
        first,second=store.read_series(),other.read_series()
        left,right=first.findings[0],second.findings[0]
        assert left['record']['id']==right['record']['id']
        assert (first.id,left['record']['id'])!=(second.id,right['record']['id'])
        assert left['digest']!=right['digest']
        request=verdict_factory(first).model_dump(mode='json')
        request['carryover'][0]['digest']=right['digest']
        with pytest.raises(CoreError) as caught:
            prepare_verdict(first,request,first.snapshot)
        assert caught.value.code=='DIGEST_MISMATCH'
        # Replacing the entire foreign record, including its valid hash, also
        # fails the review namespace check before a verdict can be accepted.
        foreign=replace(first,findings=second.findings)
        with pytest.raises(CoreError) as caught:
            prepare_verdict(foreign,verdict_factory(foreign),foreign.snapshot)
        assert caught.value.code=='CORRUPT_STATE'
        assert len(store.read_series().events)==len(other.read_series().events)==2
