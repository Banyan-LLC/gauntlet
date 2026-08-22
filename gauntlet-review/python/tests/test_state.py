import json
from pathlib import Path

import pytest

from gauntlet_review.state import (
    StateDir,
    doc_state_dir,
    prior_recommendations,
    validate_carryover_ledger,
    render_carryover_text,
)
from gauntlet_review.verdict import recommendation_id


def _sd(path) -> StateDir:
    return StateDir.open(path)


def _write_verdict(state_dir: Path, round_num: int, recs: list[dict]):
    (state_dir / f"round-{round_num}-verdict.json").write_text(
        json.dumps({"verdict": "request_changes", "summary": "s", "recommendations": recs}),
        encoding="utf-8",
    )


REC = {"severity": "blocking", "location": "L", "issue": "i", "suggestion": "s"}


def test_doc_state_dir_builds_and_creates_expected_path(tmp_path):
    d = doc_state_dir(tmp_path, topic="my-topic", phase="spec", date="2026-08-18")
    expected = (Path(tmp_path) / "docs" / "superpowers" / "reviews" / "2026-08-18-my-topic" / "spec").resolve()
    assert d.path == expected
    assert d.path.is_dir()


def test_doc_state_dir_rejects_bad_topic(tmp_path):
    with pytest.raises(ValueError):
        doc_state_dir(tmp_path, topic="Bad_Topic", phase="spec", date="2026-08-18")


def test_doc_state_dir_rejects_bad_date(tmp_path):
    with pytest.raises(ValueError):
        doc_state_dir(tmp_path, topic="t", phase="spec", date="2026/08/18")


def test_prior_recommendations_ids_match_reference(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    prior = prior_recommendations(_sd(tmp_path), up_to_round=2)
    assert len(prior) == 1
    assert prior[0]["id"] == recommendation_id(1, 0, REC)
    assert prior[0]["round"] == 1 and prior[0]["issue"] == "i"


def test_prior_recommendations_excludes_current_round(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    _write_verdict(tmp_path, 2, [REC])
    assert len(prior_recommendations(_sd(tmp_path), up_to_round=2)) == 1  # only round 1


def _ledger(state_dir, round_num, entries):
    p = state_dir / f"ledger-{round_num}.json"
    p.write_text(json.dumps({"version": 1, "round": round_num, "entries": entries}), encoding="utf-8")
    return p


def _entry(rec_id, status="addressed", reason=None, **overrides):
    e = {"id": rec_id, "severity": REC["severity"], "location": REC["location"],
         "issue": REC["issue"], "suggestion": REC["suggestion"], "status": status}
    if reason is not None:
        e["reason"] = reason
    e.update(overrides)
    return e


def test_valid_ledger_passes(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    rid = recommendation_id(1, 0, REC)
    p = _ledger(tmp_path, 2, [_entry(rid)])
    r = validate_carryover_ledger(_sd(tmp_path), 2, p)
    assert r.valid


def test_ledger_missing_when_prior_exists_fails(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    r = validate_carryover_ledger(_sd(tmp_path), 2, tmp_path / "nope.json")
    assert not r.valid and "not found" in r.reason


def test_ledger_omitted_prior_fails(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    p = _ledger(tmp_path, 2, [])
    r = validate_carryover_ledger(_sd(tmp_path), 2, p)
    assert not r.valid and "OMITTED" in r.reason


def test_ledger_invented_id_fails(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    rid = recommendation_id(1, 0, REC)
    p = _ledger(tmp_path, 2, [_entry(rid), _entry("r1-deadbeef")])
    r = validate_carryover_ledger(_sd(tmp_path), 2, p)
    assert not r.valid and "invents" in r.reason


def test_ledger_mutated_text_fails(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    rid = recommendation_id(1, 0, REC)
    p = _ledger(tmp_path, 2, [_entry(rid, issue="MUTATED")])
    r = validate_carryover_ledger(_sd(tmp_path), 2, p)
    assert not r.valid and "mutation" in r.reason


def test_ledger_disputed_without_reason_fails(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    rid = recommendation_id(1, 0, REC)
    p = _ledger(tmp_path, 2, [_entry(rid, status="disputed")])
    r = validate_carryover_ledger(_sd(tmp_path), 2, p)
    assert not r.valid and "no reason" in r.reason


def test_ledger_wrong_round_fails(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    rid = recommendation_id(1, 0, REC)
    p = _ledger(tmp_path, 3, [_entry(rid)])  # says round 3
    r = validate_carryover_ledger(_sd(tmp_path), 2, p)  # invoked for round 2
    assert not r.valid and "round" in r.reason


def test_ledger_version_true_rejected(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    rid = recommendation_id(1, 0, REC)
    p = tmp_path / "ledger-2.json"
    p.write_text(json.dumps({"version": True, "round": 2, "entries": [_entry(rid)]}), encoding="utf-8")
    r = validate_carryover_ledger(_sd(tmp_path), 2, p)
    assert not r.valid and "version" in r.reason


def test_ledger_version_float_one_rejected(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    rid = recommendation_id(1, 0, REC)
    p = tmp_path / "ledger-2.json"
    p.write_text(json.dumps({"version": 1.0, "round": 2, "entries": [_entry(rid)]}), encoding="utf-8")
    r = validate_carryover_ledger(_sd(tmp_path), 2, p)
    assert not r.valid and "version" in r.reason


def test_ledger_nan_rejected(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    p = tmp_path / "ledger-2.json"
    # NaN is not valid JSON; hand-write it (json.dumps won't emit it here).
    p.write_text('{"version": 1, "round": 2, "x": NaN, "entries": []}', encoding="utf-8")
    r = validate_carryover_ledger(_sd(tmp_path), 2, p)
    assert not r.valid and "not valid JSON" in r.reason


def test_ledger_entries_missing_rejected(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    p = tmp_path / "ledger-2.json"
    p.write_text(json.dumps({"version": 1, "round": 2}), encoding="utf-8")  # no 'entries' key
    r = validate_carryover_ledger(_sd(tmp_path), 2, p)
    assert not r.valid and "entries" in r.reason


def test_ledger_non_string_id_rejected(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    p = tmp_path / "ledger-2.json"
    entry = {**_entry("placeholder"), "id": 123}
    p.write_text(json.dumps({"version": 1, "round": 2, "entries": [entry]}), encoding="utf-8")
    r = validate_carryover_ledger(_sd(tmp_path), 2, p)
    assert not r.valid and "id" in r.reason


def test_ledger_non_string_status_rejected(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    rid = recommendation_id(1, 0, REC)
    p = tmp_path / "ledger-2.json"
    entry = {**_entry(rid), "status": ["addressed"]}  # a list must not raise TypeError
    p.write_text(json.dumps({"version": 1, "round": 2, "entries": [entry]}), encoding="utf-8")
    r = validate_carryover_ledger(_sd(tmp_path), 2, p)
    assert not r.valid and "status" in r.reason


def test_doc_state_dir_rejects_symlinked_reviews_escape(tmp_path):
    # A symlinked reviews dir pointing outside the repo must not let writes escape.
    outside = tmp_path / "outside"
    outside.mkdir()
    repo = tmp_path / "repo"
    (repo / "docs" / "superpowers").mkdir(parents=True)
    try:
        (repo / "docs" / "superpowers" / "reviews").symlink_to(outside, target_is_directory=True)
    except (OSError, NotImplementedError):
        pytest.skip("symlinks not supported on this platform/privilege")
    with pytest.raises(ValueError):
        doc_state_dir(repo, topic="t", phase="spec", date="2026-08-18")
    assert list(outside.iterdir()) == []  # no external write occurred through the symlink


def test_read_text_rejects_symlinked_state_file(tmp_path):
    # A symlinked verdict file inside the state dir must not be followed.
    outside = tmp_path / "secret.json"
    outside.write_text('{"verdict":"approve","summary":"x","recommendations":[]}', encoding="utf-8")
    sd_path = tmp_path / "sd"
    sd_path.mkdir()
    try:
        (sd_path / "round-1-verdict.json").symlink_to(outside)
    except (OSError, NotImplementedError):
        pytest.skip("symlinks not supported on this platform/privilege")
    with pytest.raises((ValueError, OSError)):
        prior_recommendations(_sd(sd_path), up_to_round=2)


def test_doc_state_dir_rejects_trailing_newline(tmp_path):
    with pytest.raises(ValueError):
        doc_state_dir(tmp_path, topic="t\n", phase="spec", date="2026-08-18")
    with pytest.raises(ValueError):
        doc_state_dir(tmp_path, topic="t", phase="spec", date="2026-08-18\n")


def test_ledger_surrogate_reason_rejected(tmp_path):
    _write_verdict(tmp_path, 1, [REC])
    rid = recommendation_id(1, 0, REC)
    p = tmp_path / "ledger-2.json"
    entry = _entry(rid, status="disputed", reason="ok " + chr(0xD800))
    p.write_text(json.dumps({"version": 1, "round": 2, "entries": [entry]}), encoding="utf-8")
    r = validate_carryover_ledger(_sd(tmp_path), 2, p)
    assert not r.valid and "surrogate" in r.reason


def test_closed_statedir_raises_not_fallback(tmp_path):
    # After close(), reads must RAISE, never silently degrade to path-based I/O.
    _write_verdict(tmp_path, 1, [REC])
    sd = StateDir.open(tmp_path)
    sd.close()
    with pytest.raises(ValueError):
        sd.read_text("round-1-verdict.json")


def test_render_carryover_text_sorted_and_labeled(tmp_path):
    entries = [
        {"id": "r1-bbb", "severity": "nit", "location": "L2", "issue": "i2", "suggestion": "s2", "status": "addressed", "reason": None},
        {"id": "r1-aaa", "severity": "blocking", "location": "L1", "issue": "i1", "suggestion": "s1", "status": "disputed", "reason": "why"},
    ]
    text = render_carryover_text(entries)
    assert text.startswith("== PRIOR ROUNDS (trusted) ==")
    assert text.index("r1-aaa") < text.index("r1-bbb")  # sorted by id
    assert "status: disputed — why" in text


def test_render_carryover_text_empty_is_blank():
    assert render_carryover_text([]) == ""
