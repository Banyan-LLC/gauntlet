import json

from gauntlet_review.usage import parse_run_usage


def _stream(*events):
    # A real process's stdout ends with a trailing newline -> a trailing "" element after split.
    return [json.dumps(e) for e in events] + [""]


def test_happy_path_single_turn_completed():
    r = parse_run_usage(_stream(
        {"type": "thread.started"},
        {"type": "turn.completed", "usage": {"input_tokens": 9456}},
    ))
    assert r.ok and r.input_tokens == 9456
    assert json.loads(r.raw_line)["type"] == "turn.completed"


def test_blank_lines_are_skipped():
    r = parse_run_usage(["", "  ", json.dumps({"type": "turn.completed", "usage": {"input_tokens": 5}}), ""])
    assert r.ok and r.input_tokens == 5


def test_non_json_line_fails_closed():
    r = parse_run_usage(["not json", json.dumps({"type": "turn.completed", "usage": {"input_tokens": 5}})])
    assert not r.ok and "not valid JSON" in r.reason


def test_bare_non_object_line_fails_closed():
    r = parse_run_usage(["5"])
    assert not r.ok and "did not parse to a JSON object" in r.reason


def test_object_without_type_fails_closed():
    r = parse_run_usage([json.dumps({"usage": {"input_tokens": 5}})])
    assert not r.ok and "no 'type' field" in r.reason


def test_top_level_error_event_fails():
    r = parse_run_usage(_stream({"type": "error"}, {"type": "turn.completed", "usage": {"input_tokens": 5}}))
    assert not r.ok and "top-level error" in r.reason


def test_turn_failed_event_fails():
    r = parse_run_usage(_stream({"type": "turn.failed"}))
    assert not r.ok and "turn.failed" in r.reason


def test_zero_turn_completed_fails():
    r = parse_run_usage(_stream({"type": "thread.started"}))
    assert not r.ok and "no turn.completed" in r.reason


def test_two_turn_completed_fails():
    r = parse_run_usage(_stream(
        {"type": "turn.completed", "usage": {"input_tokens": 5}},
        {"type": "turn.completed", "usage": {"input_tokens": 6}},
    ))
    assert not r.ok and "expected exactly one" in r.reason


def test_missing_usage_fails():
    r = parse_run_usage(_stream({"type": "turn.completed"}))
    assert not r.ok and "no usage" in r.reason


def test_non_integer_input_tokens_fails():
    r = parse_run_usage(_stream({"type": "turn.completed", "usage": {"input_tokens": "9456"}}))
    assert not r.ok and "not an integer" in r.reason


def test_boolean_input_tokens_rejected():
    r = parse_run_usage(_stream({"type": "turn.completed", "usage": {"input_tokens": True}}))
    assert not r.ok and "not an integer" in r.reason


def test_non_positive_input_tokens_fails():
    r = parse_run_usage(_stream({"type": "turn.completed", "usage": {"input_tokens": 0}}))
    assert not r.ok and "positive integer" in r.reason


def test_nan_constant_rejected():
    # Python json.loads accepts NaN/Infinity by default; the gate must reject them.
    r = parse_run_usage(['{"type":"thread.started","x":NaN}',
                         json.dumps({"type": "turn.completed", "usage": {"input_tokens": 5}})])
    assert not r.ok and "not valid JSON" in r.reason


def test_infinity_constant_rejected():
    r = parse_run_usage(['{"type":"turn.completed","usage":{"input_tokens":5},"y":Infinity}'])
    assert not r.ok and "not valid JSON" in r.reason
