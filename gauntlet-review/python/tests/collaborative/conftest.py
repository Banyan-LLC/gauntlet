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


class GitFixture:
    def __init__(self, config):
        from dulwich.repo import Repo
        self.config = config
        self.repo = Repo(str(config.repo_path))
        self.counter = 0

    def commit(self, files, parents=None):
        from dulwich.objects import Blob, Commit, Tree
        nested = {}
        for path, (mode, body) in files.items():
            parts = path.split(b"/")
            current = nested
            for part in parts[:-1]:
                current = current.setdefault(part, {})
            if mode == 0o160000:
                oid = body.encode("ascii") if isinstance(body, str) else body
            else:
                blob = Blob.from_string(body)
                self.repo.object_store.add_object(blob)
                oid = blob.id
            current[parts[-1]] = mode, oid

        def tree(entries):
            result = Tree()
            for name, value in entries.items():
                mode, oid = (0o040000, tree(value)) if isinstance(value, dict) else value
                result.add(name, mode, oid)
            self.repo.object_store.add_object(result)
            return result.id

        self.counter += 1
        commit = Commit()
        commit.tree = tree(nested)
        commit.parents = [p.encode("ascii") for p in (parents or [])]
        commit.author = commit.committer = b"Fixture <fixture@example.invalid>"
        commit.author_time = commit.commit_time = self.counter
        commit.author_timezone = commit.commit_timezone = 0
        commit.message = f"fixture {self.counter}\n".encode("ascii")
        self.repo.object_store.add_object(commit)
        return commit.id.decode("ascii")

    def set_ref(self, ref, oid):
        self.repo.refs[ref] = oid.encode("ascii")

    def write_worktree_file(self, path, data):
        target = self.config.repo_path / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    def pair(self, old, new):
        base = self.commit(old)
        head = self.commit(new, parents=[base])
        self.set_ref(self.config.target_ref, base)
        self.set_ref(self.config.source_ref, head)
        self.repo.refs.set_symbolic_ref(b"HEAD", self.config.target_ref)
        return base, head


@pytest.fixture
def git_fixture(cfg):
    fixture = GitFixture(cfg)
    try:
        yield fixture
    finally:
        fixture.repo.close()
