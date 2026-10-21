import pytest

pytest.importorskip("mcp")
pytest.importorskip("dulwich")
pytest.importorskip("pydantic")


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
def valid_open_payload():
    return {"key": "initial", "expected_version": 0}


@pytest.fixture
def cfg(tmp_path):
    from dulwich.repo import Repo
    from gauntlet_review.collaborative.contracts import OperatorConfig
    repo = tmp_path / "repo"
    repo.mkdir()
    Repo.init(str(repo)).close()
    state = tmp_path / "state"
    state.mkdir(mode=0o700)
    return OperatorConfig(repo, state, "fixture", b"refs/heads/topic", b"refs/heads/main",
                          "author", "author")
