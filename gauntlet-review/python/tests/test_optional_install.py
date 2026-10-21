"""Runs in either environment; isolation of installation is driven externally."""
import sys
import importlib.util
import os
import pytest


def test_legacy_import_has_no_optional_startup_side_effects():
    before = set(sys.modules)
    import gauntlet_review
    from gauntlet_review import jcs, verdict
    assert gauntlet_review and jcs and verdict
    added = set(sys.modules) - before
    assert not any(name == root or name.startswith(root + ".")
                   for root in ("mcp", "dulwich", "pydantic") for name in added)


@pytest.mark.skipif(os.environ.get("GAUNTLET_EXPECT_BASE_ONLY") != "1", reason="separate base-only environment")
def test_base_installation_does_not_resolve_optional_dependencies():
    assert all(importlib.util.find_spec(name) is None for name in ("mcp", "dulwich", "pydantic"))
