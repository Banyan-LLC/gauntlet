import json
from pathlib import Path

from gauntlet_review.verdict import normalize_verdict

SCHEMA = Path(__file__).resolve().parents[2] / "schemas" / "verdict.schema.json"
assert SCHEMA.is_file(), f"schema fixture not found: {SCHEMA}"


def _verdict(verdict, recs):
    return json.dumps({"verdict": verdict, "summary": "s", "recommendations": recs})


def test_valid_request_changes_passes_unchanged():
    r = normalize_verdict(_verdict("request_changes", []), SCHEMA)
    assert r.valid and not r.downgraded
    assert r.normalized["verdict"] == "request_changes"
    assert r.canonical_json == '{"recommendations":[],"summary":"s","verdict":"request_changes"}'


def test_approve_with_only_nits_stays_approve():
    recs = [{"severity": "nit", "location": "L", "issue": "i", "suggestion": "s"}]
    r = normalize_verdict(_verdict("approve", recs), SCHEMA)
    assert r.valid and not r.downgraded
    assert r.normalized["verdict"] == "approve"


def test_approve_with_blocking_is_downgraded():
    recs = [{"severity": "blocking", "location": "L", "issue": "i", "suggestion": "s"}]
    r = normalize_verdict(_verdict("approve", recs), SCHEMA)
    assert r.valid and r.downgraded
    assert r.normalized["verdict"] == "request_changes"
    assert "downgraded" in r.reason


def test_structurally_invalid_extra_property_fails():
    bad = json.dumps({"verdict": "approve", "summary": "s", "recommendations": [], "extra": 1})
    r = normalize_verdict(bad, SCHEMA)
    assert not r.valid and r.reason == "structural validation failed"


def test_summary_over_800_fails():
    r = normalize_verdict(json.dumps({"verdict": "request_changes", "summary": "x" * 801, "recommendations": []}), SCHEMA)
    assert not r.valid


def test_non_json_fails_cleanly():
    r = normalize_verdict("{not json", SCHEMA)
    assert not r.valid
