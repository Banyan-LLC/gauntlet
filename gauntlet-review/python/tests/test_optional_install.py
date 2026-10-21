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
                   for root in ("mcp", "dulwich", "pydantic", "openai_codex") for name in added)


@pytest.mark.skipif(os.environ.get("GAUNTLET_EXPECT_BASE_ONLY") != "1", reason="separate base-only environment")
def test_base_installation_does_not_resolve_optional_dependencies():
    assert all(importlib.util.find_spec(name) is None for name in ("mcp", "dulwich", "pydantic", "openai_codex"))


@pytest.mark.skipif(os.environ.get("GAUNTLET_EXPECT_BASE_ONLY") != "1", reason="separate base-only environment")
def test_missing_extra_startup_is_short_and_has_no_optional_import_side_effects(tmp_path,capsys):
    from gauntlet_review.collaborative.server import main
    flags=["--repo",str(tmp_path/"repo"),"--state-dir",str(tmp_path/"state"),"--repository-id","fixture",
           "--source-ref","refs/heads/topic","--target-ref","refs/heads/main","--participant","author","--role","author"]
    assert main(flags) == 2
    captured=capsys.readouterr()
    assert captured.out == "" and "[mcp]" in captured.err and "Traceback" not in captured.err
    assert not (tmp_path/"state").exists()
    assert not any(name in sys.modules for name in ("mcp","dulwich","pydantic"))


@pytest.mark.skipif(os.environ.get("GAUNTLET_EXPECT_BASE_ONLY") != "1", reason="separate base-only environment")
def test_base_sdk_adapter_refuses_without_importing_any_optional_package(tmp_path,capsys):
    from gauntlet_review.codex_bridge.server import main
    flags=["--repo",str(tmp_path/"repo"),"--state-dir",str(tmp_path/"state"),"--repository-id","fixture",
        "--source-ref","refs/heads/topic","--target-ref","refs/heads/main","--participant","peer"]
    assert main(flags)==2
    output=capsys.readouterr()
    assert not output.out and "[codex]" in output.err and "Traceback" not in output.err
    assert not (tmp_path/"state").exists()
    assert not any(name in sys.modules for name in ("mcp","dulwich","pydantic","openai_codex"))
