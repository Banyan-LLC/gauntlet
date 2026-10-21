import pytest

pytest.importorskip("mcp")
pytest.importorskip("dulwich")
pytest.importorskip("pydantic")


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
def config(tmp_path):
    from gauntlet_review.collaborative.contracts import OperatorConfig
    from gauntlet_review.codex_bridge.engine import BridgeConfig
    return BridgeConfig(OperatorConfig(tmp_path/"repo",tmp_path/"state","fixture",
        b"refs/heads/topic",b"refs/heads/main","peer","reviewer"),timeout_seconds=10)
