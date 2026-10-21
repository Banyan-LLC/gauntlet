"""Boundary cases that would admit invalid identities, unbounded text or lost closure."""
from dataclasses import replace
import base64
import math
from pathlib import Path

import pytest
import warnings


def api():
    from gauntlet_review.collaborative import contracts
    return contracts


def verdict():
    return dict(key="once", expected_version=0, review_id="a" * 32,
                revision_id="b" * 32, snapshot_digest="c" * 64,
                verdict="approve", summary="reviewed", recommendations=[],
                coverage_digest="d" * 64, coverage=[], carryover=[])


def evidence():
    return dict(key="once", expected_version=0, review_id="a" * 32,
                revision_id="b" * 32, snapshot_digest="c" * 64,
                origin="agent_report", command="pytest", runtime="Python",
                exit_status=0, content={"kind": "inline", "data_b64": "aGk="})


def rejected(operation, payload):
    c = api()
    with pytest.raises(c.CoreError) as error:
        c.validate_request(operation, payload)
    assert error.value.code == "INVALID_ARGUMENT"
    assert not error.value.retryable


@pytest.mark.parametrize("version", [True, False, 0.0, 1.5, math.inf, math.nan, -1, 2**53, "0", None])
def test_version_cannot_coerce_or_leave_exact_integer_domain(valid_open_payload, version):
    rejected("open_review", {**valid_open_payload, "expected_version": version})


@pytest.mark.parametrize("key", ["", "x" * 65, "a b", "x\n", "é", "\\", True, None])
def test_mutation_key_is_a_bounded_ascii_identifier(valid_open_payload, key):
    rejected("open_review", {**valid_open_payload, "key": key})


def test_core_revalidates_model_and_refuses_identity_override(valid_open_payload):
    c = api()
    value = c.validate_request("open_review", valid_open_payload)
    assert value.expected_version == 0
    rejected("open_review", {**valid_open_payload, "role": "reviewer"})
    rejected("open_review", {**valid_open_payload, "repo_path": "/tmp"})
    value.__dict__["expected_version"] = True
    rejected("open_review", value)


@pytest.mark.parametrize("identity", ["A" * 32, "a" * 31, "a" * 33, "a" * 32 + "\n", "z" * 32])
def test_revision_ids_are_full_lowercase_hex(identity):
    rejected("submit_review", {**verdict(), "revision_id": identity})


@pytest.mark.parametrize("field,limit", [("location", 150), ("issue", 500), ("suggestion", 500)])
def test_finding_text_limit_counts_utf8_bytes(field, limit):
    c = api()
    item = dict(severity="important", location="line", issue="defect", suggestion="fix")
    item[field] = "😀" * (limit // 4) + "x" * (limit % 4)
    request = {**verdict(), "recommendations": [item]}
    assert c.validate_request("submit_review", request).recommendations[0].model_dump()[field] == item[field]
    rejected("submit_review", {**request, "recommendations": [{**item, field: item[field] + "x"}]})


@pytest.mark.parametrize("text", ["x\x00", "x\x01", "x\x1f", "\ud800", "\udfff"])
def test_invalid_unicode_and_c0_are_refused_in_nested_text(text):
    rejected("submit_review", {**verdict(), "summary": text})
    rejected("record_evidence", {**evidence(), "command": text})
    item = dict(severity="nit", location="file", issue=text, suggestion="fix")
    rejected("submit_review", {**verdict(), "recommendations": [item]})


def test_escaped_and_four_byte_text_is_preserved_without_normalization():
    c = api()
    text = '\\"\t\r\n😀e\u0301'
    request = c.validate_request("submit_review", {**verdict(), "summary": text})
    assert request.summary == text
    assert c.encode({"summary": text}) == b'{"summary":"\\\\\\"\\t\\r\\n\xf0\x9f\x98\x80e\xcc\x81"}'


def test_enums_extra_nested_properties_and_duplicates_are_refused():
    rejected("submit_review", {**verdict(), "verdict": "approved"})
    rejected("submit_review", {**verdict(), "coverage": ["a" * 32, "a" * 32]})
    item = dict(severity="major", location="line", issue="defect", suggestion="fix")
    rejected("submit_review", {**verdict(), "recommendations": [item]})
    prior = dict(id="r1-" + "e" * 32, digest="f" * 64, status="outstanding", reason="")
    rejected("submit_review", {**verdict(), "carryover": [prior]})
    rejected("submit_review", {**verdict(), "carryover": [{**prior, "reason": "checking", "issue": "replacement"}]})


@pytest.mark.parametrize("id", ["r0-" + "a" * 32, "r11-" + "a" * 32, "r1-" + "a" * 32 + "\n"])
def test_finding_round_id_cannot_exceed_accepted_rounds(id):
    rejected("submit_review", {**verdict(), "carryover": [dict(id=id, digest="f" * 64,
              status="addressed", reason="")]})


def test_capacity_uses_actual_model_and_canonical_encoder():
    c = api()
    request = dict(key="k"*64, expected_version=2**53-1, review_id="a"*32,
        revision_id="b"*32, snapshot_digest="c"*64, verdict="request_changes",
        summary="\\"*800, coverage_digest="d"*64,
        coverage=[f"{i:032x}" for i in range(1000)],
        recommendations=[dict(severity="important", location="\\"*150,
            issue="\\"*500, suggestion="\\"*500) for _ in range(20)],
        carryover=[dict(id="r10-"+f"{i:032x}", digest="e"*64,
            status="outstanding", reason="\\"*256) for i in range(200)])
    parsed = c.validate_request("submit_review", request)
    measured = len(c.encode({"request": parsed.model_dump(mode="json")}))
    assert measured == 218196
    assert c.verdict_capacity(200) == measured
    assert measured < 262144
    rejected("submit_review", {**request, "summary": "\\"*801})


@pytest.mark.parametrize("field,limit", [("command",2048), ("runtime",256)])
def test_evidence_metadata_is_bounded(field, limit):
    c=api()
    c.validate_request("record_evidence", {**evidence(), field:"x"*limit})
    rejected("record_evidence", {**evidence(), field:"x"*(limit+1)})


@pytest.mark.parametrize("status", [True, 1.0, -2**31-1, 2**31])
def test_claimed_exit_is_nullable_signed32_and_strict(status):
    rejected("record_evidence", {**evidence(), "exit_status": status})


def test_inline_evidence_is_strict_canonical_bounded_base64():
    c=api()
    for invalid in ("aGk", "aGk===", "aGk=\n", "aGm=", "é"):
        rejected("record_evidence", {**evidence(), "content":{"kind":"inline", "data_b64":invalid}})
    for size in (0, 256*1024):
        payload = base64.b64encode(b"x"*size).decode("ascii")
        c.validate_request("record_evidence", {**evidence(), "content":{"kind":"inline", "data_b64":payload}})
    payload = base64.b64encode(b"x"*(256*1024+1)).decode("ascii")
    rejected("record_evidence", {**evidence(), "content":{"kind":"inline", "data_b64":payload}})


def test_external_reference_is_only_a_bounded_descriptor():
    c=api()
    content=dict(kind="external", uri="https://example.invalid/archive", length=10, sha256="f"*64)
    parsed=c.validate_request("record_evidence", {**evidence(), "content":content})
    assert parsed.content.uri == content["uri"]
    rejected("record_evidence", {**evidence(), "content":{**content, "uri":"x"*4097}})
    rejected("record_evidence", {**evidence(), "content":{**content, "length":True}})


def test_read_requests_cannot_open_paths_or_exceed_page_bounds():
    request=dict(review_id="a"*32, revision_id="b"*32, snapshot_digest="c"*64,
                 view="artifact", artifact_id="d"*32, offset=0, length=65536)
    c=api()
    assert c.validate_request("read_review", request).length == 65536
    for addition in ({"path":"/etc/passwd"}, {"length":65537}, {"length":0}, {"offset":True},
                     {"view":"unknown"}, {"cursor":"x"}):
        rejected("read_review", {**request, **addition})
    rejected("read_review", {k:v for k,v in request.items() if k != "artifact_id"})


@pytest.mark.parametrize("field", ["repo_path", "state_dir"])
@pytest.mark.parametrize("path", ["repo", "./repo", "../repo", "C:repo", "\\repo", "//server/share"])
def test_configuration_refuses_nonabsolute_native_paths_before_open(cfg, field, path):
    c=api()
    with pytest.raises(c.CoreError) as error:
        c.validate_operator_config(replace(cfg, **{field:Path(path)}))
    assert error.value.code == "CONFIGURATION_ERROR"


@pytest.mark.parametrize("field,value", [("role","admin"), ("repository_id","é"),
    ("participant",""), ("source_ref",b"refs/remotes/origin/topic"),
    ("source_ref",b"refs/heads/a..b"), ("target_ref",b"refs/heads/a.lock"),
    ("target_ref",b"refs/heads/a\n"), ("target_ref",b"refs/heads/a@{b")])
def test_operator_identity_and_refs_cannot_be_reinterpreted(cfg, field, value):
    c=api()
    with pytest.raises(c.CoreError) as error:
        c.validate_operator_config(replace(cfg, **{field:value}))
    assert error.value.code == "CONFIGURATION_ERROR"


def test_encoder_refuses_noncanonical_values_without_echoing_them():
    c=api()
    for value in ({"x":float("nan")}, {"x":b"secret"}, {"\ud800":"secret"}):
        with pytest.raises(c.CoreError) as error:
            c.encode(value)
        assert error.value.code == "INVALID_ARGUMENT"
        assert "secret" not in str(error.value.detail)


def test_model_revalidation_never_emits_input_in_serializer_warnings():
    c=api()
    model=c.validate_request("submit_review", verdict())
    model.__dict__["coverage"] = "private-source-content"
    with warnings.catch_warnings(record=True) as captured:
        warnings.simplefilter("always")
        rejected("submit_review", model)
    assert not captured


def test_verdict_count_and_every_text_budget_are_enforced():
    c=api()
    item=dict(severity="nit", location="line", issue="issue", suggestion="fix")
    c.validate_request("submit_review", {**verdict(), "summary":"😀"*200, "recommendations":[item]*20})
    rejected("submit_review", {**verdict(), "summary":"😀"*200+"x"})
    rejected("submit_review", {**verdict(), "recommendations":[item]*21})
    coverage=[f"{n:032x}" for n in range(1001)]
    c.validate_request("submit_review", {**verdict(), "coverage":coverage[:1000]})
    rejected("submit_review", {**verdict(), "coverage":coverage})
    prior=dict(id="r10-"+"f"*32, digest="e"*64, status="disputed", reason="😀"*64)
    c.validate_request("submit_review", {**verdict(), "carryover":[prior]})
    rejected("submit_review", {**verdict(), "carryover":[{**prior, "reason":prior["reason"]+"x"}]})
    for field in ("snapshot_digest", "coverage_digest"):
        for digest in ("a"*63, "a"*65, "F"*64, "g"*64):
            rejected("submit_review", {**verdict(), field:digest})


def test_evidence_cannot_claim_server_verification_or_producer_identity():
    c=api()
    for status in (None, -2**31, 2**31-1):
        c.validate_request("record_evidence", {**evidence(), "exit_status":status})
    for field, value in (("producer","other"), ("verified",True), ("origin","trusted_ci")):
        rejected("record_evidence", {**evidence(), field:value})
    rejected("record_evidence", {**evidence(), "content":{**evidence()["content"], "verified":True}})
    rejected("review_status", {"role":"reviewer"})
    rejected("unknown_operation", {})
