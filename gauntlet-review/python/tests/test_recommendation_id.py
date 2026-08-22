from gauntlet_review.verdict import recommendation_id


def test_matches_powershell_reference_ascii():
    rec = {"severity": "blocking", "location": "file.py:10", "issue": "bug", "suggestion": "fix it"}
    assert recommendation_id(1, 0, rec) == "r1-e29bad181f048478478bb8447e9182fc"


def test_matches_powershell_reference_round_and_index_affect_id():
    rec = {"severity": "nit", "location": "section 2", "issue": "typo: cafe accent e", "suggestion": "correct it"}
    assert recommendation_id(3, 2, rec) == "r3-0740d612b704851d0f3ba7477d976a27"


def test_matches_powershell_reference_pipe_and_newline_in_fields():
    rec = {"severity": "important", "location": "L", "issue": "multi\nline", "suggestion": "a|b|c"}
    assert recommendation_id(2, 0, rec) == "r2-c579b558a6f78cbbbaeee5fd2baa29af"
