"""Keep legacy session creation faithful while retaining matrix custody."""
import os
from pathlib import Path
import shutil
import subprocess

import pytest

GIT = shutil.which("git")
GIT_IDENTITY = {"GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}


def _git(cwd, *args):
    subprocess.run([GIT, "-C", str(cwd), *args], check=True, capture_output=True, env={**os.environ, **GIT_IDENTITY})


@pytest.fixture
def run_git():
    """git -C <cwd> <args> with a fixed identity (skips without git)."""
    if GIT is None:
        pytest.skip("git is needed to build the fixture repositories")
    return _git


@pytest.fixture
def make_checkout(tmp_path, run_git):
    """make_checkout(name, branch): a clone of one bare origin (default branch main, URL rewritten to
    git@github.com:Owner/Repo.git) with `branch` checked out. Every call shares the same origin."""
    origin = tmp_path / "Owner" / "Repo.git"

    def make(name="work", branch="feature/x"):
        if not origin.exists():
            origin.mkdir(parents=True)
            run_git(origin, "init", "--bare", "-q", "-b", "main")
            seed = tmp_path / "seed"
            run_git(tmp_path, "clone", "-q", str(origin), str(seed))
            (seed / "a.txt").write_text("one\n")
            run_git(seed, "add", "a.txt")
            run_git(seed, "commit", "-q", "-m", "one")
            run_git(seed, "push", "-q", "origin", "HEAD:main")
        work = tmp_path / name
        run_git(tmp_path, "clone", "-q", str(origin), str(work))
        run_git(work, "checkout", "-q", "-b", branch)
        run_git(work, "remote", "set-url", "origin", "git@github.com:Owner/Repo.git")
        return work
    return make


@pytest.fixture(autouse=True)
def legacy_session_custody(monkeypatch):
    if os.name=="posix" and os.environ.get("GAUNTLET_TEST_TRACK_LEGACY_SESSIONS")=="1":
        support=Path(__file__).resolve().parents[3]/"tests/support"
        monkeypatch.syspath_prepend(str(support))
        from collaborative_legacy import track_sessions
        monkeypatch.setattr(subprocess,"Popen",track_sessions(subprocess.Popen))
