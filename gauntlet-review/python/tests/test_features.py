import pytest

from gauntlet_review.features import FEATURE_ALLOWLIST, disable_set


def test_allowlist_is_exactly_the_five():
    assert FEATURE_ALLOWLIST == frozenset(
        {"enable_request_compression", "remote_compaction_v2", "fast_mode", "personality", "guardian_approval"}
    )


def test_disables_everything_not_allowlisted_sorted_unique():
    enumerated = ["shell_tool", "apps", "fast_mode", "apps", "personality", "browser_use"]
    assert disable_set(enumerated) == ["apps", "browser_use", "shell_tool"]


def test_allowlisted_only_yields_empty():
    assert disable_set(list(FEATURE_ALLOWLIST)) == []


def test_empty_enumeration_yields_empty():
    assert disable_set([]) == []


def test_empty_string_element_raises():
    with pytest.raises(ValueError):
        disable_set(["apps", ""])


def test_none_element_raises():
    with pytest.raises(ValueError):
        disable_set(["apps", None])  # type: ignore[list-item]
