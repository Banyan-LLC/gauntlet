"""The live opt-in and declared fixture failures cannot fabricate peer reviews."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import sys

import pytest
pytest.importorskip("openai_codex")

ROOT=Path(__file__).resolve().parents[4]
DRIVER=ROOT/"tests/live/collaborative-workflow.py"
sys.path.insert(0,str(ROOT/"tests/support"))
from collaborative_process import ExpectedExit,run_case


def load():
    spec=importlib.util.spec_from_file_location("live_driver",DRIVER)
    module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def test_live_run_requires_explicit_opt_in_before_archive_creation(tmp_path):
    module=load(); target=tmp_path/"not-created"
    with pytest.raises(SystemExit) as error:
        module.main(["--archive",str(target)])
    assert error.value.code==2 and not target.exists()


def test_fixture_is_committed_clean_and_preserves_intended_api(tmp_path):
    from dulwich import porcelain
    from dulwich.repo import Repo
    module=load(); tmp_path.joinpath("run").mkdir()
    metadata=module.prepare_fixture(tmp_path/"run",sys.executable)
    with Repo(metadata["repo_path"]) as repo:
        status=porcelain.status(repo)
        assert not status.unstaged and not status.untracked and not any(status.staged.values())
        assert repo.refs[b"refs/heads/main"]!=repo.refs[b"refs/heads/review-topic"]
        commit=repo[repo.head()]
        assert commit.author==commit.committer==b"geoffroth <geoffroth@gmail.com>"
    assert "discount_percent" in Path(metadata["repo_path"],"discount.py").read_text()
    assert metadata["initial_source_oid"]!=metadata["base_oid"]


def test_declared_failing_baseline_retains_the_original_exit_and_bytes(tmp_path):
    module=load(); archive=tmp_path/"run"; archive.mkdir()
    metadata=module.prepare_fixture(archive,sys.executable)
    outcome=run_case([sys.executable,str(DRIVER),"--test","before","--archive",str(archive)],
        cwd=ROOT,environment=dict(os.environ),deadline_seconds=60,expected=ExpectedExit())
    assert outcome.completed and outcome.tree_retired and outcome.exit_code==0
    report=json.loads(outcome.stdout.prefix)
    assert report["exit_status"]==1
    original=json.loads(Path(report["receipt"]).read_text())
    assert original["completed"] and original["exit_code"]==1 and original["tree_retired"]
    data=base64.b64decode(original["stdout"]["prefix"])+base64.b64decode(original["stderr"]["prefix"])
    assert base64.b64decode(report["data_b64"])==data and b"FAILED (failures=1)" in data
    assert report["head_oid"]==metadata["initial_source_oid"]


def test_altered_regression_tests_cannot_produce_acceptance_evidence(tmp_path):
    from dulwich.repo import Repo
    module=load(); archive=tmp_path/"run"; archive.mkdir()
    metadata=module.prepare_fixture(archive,sys.executable)
    with Repo(metadata["repo_path"]) as repo:
        Path(metadata["repo_path"],"test_discount.py").write_text("import unittest\n",encoding="utf-8")
        repo.get_worktree().stage(["test_discount.py"])
        repo.get_worktree().commit(message=b"fixture altered tests\n",author=module.IDENTITY,committer=module.IDENTITY)
    with pytest.raises(RuntimeError,match="regression"):
        module.test_phase(archive,"after")
    assert not (archive/"after-run.json").exists()


def test_committed_correct_fix_produces_original_passing_test_evidence(tmp_path):
    from dulwich.repo import Repo
    module=load(); archive=tmp_path/"run"; archive.mkdir()
    metadata=module.prepare_fixture(archive,sys.executable)
    with Repo(metadata["repo_path"]) as repo:
        Path(metadata["repo_path"],"discount.py").write_text(module.CORRECT,encoding="utf-8",newline="\n")
        repo.get_worktree().stage(["discount.py"])
        fixed=repo.get_worktree().commit(message=b"fix: apply percentage to the total\n",author=module.IDENTITY,committer=module.IDENTITY)
    outcome=run_case([sys.executable,str(DRIVER),"--test","after","--archive",str(archive)],
        cwd=ROOT,environment=dict(os.environ),deadline_seconds=60,expected=ExpectedExit())
    assert outcome.completed and outcome.tree_retired
    report=json.loads(outcome.stdout.prefix)
    assert report["head_oid"]==fixed.decode() and report["exit_status"]==0
    assert b"Ran 2 tests" in base64.b64decode(report["data_b64"])
    assert b"OK" in base64.b64decode(report["data_b64"])
