import pytest
from gauntlet_review.jcs import canonical, canonical_bytes


def test_object_keys_sorted_and_no_whitespace():
    assert canonical({"b": 1, "a": "x"}) == '{"a":"x","b":1}'


def test_string_escaping_quote_backslash_and_short_controls():
    # " and \ escape; the five short control escapes are used; other controls are \u00xx.
    assert canonical('he said "hi"\n\t\\ end\x01') == r'"he said \"hi\"\n\t\\ end\u0001"'


def test_non_ascii_is_emitted_as_utf8_not_escaped():
    assert canonical_bytes({"x": "café"}) == '{"x":"café"}'.encode("utf-8")


def test_bool_null_int_and_nested():
    assert canonical({"k": [True, False, None, 0, -3]}) == '{"k":[true,false,null,0,-3]}'


def test_keys_sorted_by_utf16_code_units():
    # "Z" (0x5A) sorts before "a" (0x61) by code unit.
    assert canonical({"a": 1, "Z": 2}) == '{"Z":2,"a":1}'


def test_no_trailing_newline():
    assert not canonical({"a": 1}).endswith("\n")


def test_float_is_rejected():
    with pytest.raises(TypeError):
        canonical({"x": 1.5})


def test_int_at_exact_boundary_ok_and_beyond_rejected():
    assert canonical(2 ** 53 - 1) == str(2 ** 53 - 1)
    with pytest.raises(ValueError):
        canonical(2 ** 53)


def test_lone_surrogate_value_rejected():
    with pytest.raises(ValueError):
        canonical(chr(0xD800))
    with pytest.raises(ValueError):
        canonical_bytes({"k": chr(0xDC00)})


def test_lone_surrogate_key_rejected():
    with pytest.raises(ValueError):
        canonical({chr(0xD800): 1})


def test_non_string_key_rejected():
    with pytest.raises(TypeError):
        canonical({1: "x"})
