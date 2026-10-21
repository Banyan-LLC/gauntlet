"""Real stdio/SDK runtime cases; every descendant belongs to the external owner."""
import json
import os
from pathlib import Path
import sys

import pytest
pytest.importorskip("openai_codex")

SUPPORT=Path(__file__).resolve().parents[4]/"tests/support"
sys.path.insert(0,str(SUPPORT))
from collaborative_process import CommandFailure,ExpectedExit,run_case


def execute(config,mode,seconds=90):
    try:
        return run_case([sys.executable,str(SUPPORT/"collaborative_sdk_smoke.py"),
            "--repo",str(config.operator.repo_path),"--state",str(config.operator.state_dir),"--mode",mode],
            cwd=SUPPORT,environment=dict(os.environ),deadline_seconds=seconds,expected=ExpectedExit())
    except CommandFailure as error:
        return error.outcome


@pytest.mark.parametrize("mode",["smoke","stdio","cancel"])
def test_installed_runtime_and_real_mcp_close_without_model_calls(config,mode):
    from dulwich.repo import Repo
    config.operator.repo_path.mkdir()
    Repo.init(str(config.operator.repo_path)).close()
    config.operator.state_dir.mkdir(mode=0o700)
    outcome=execute(config,mode)
    assert outcome.completed and outcome.exit_code==0 and outcome.tree_retired,outcome
    report=json.loads(outcome.stdout.prefix)
    assert report["model_calls"]==0
    if mode!="stdio":
        assert report["sdk"]==report["runtime"]=="0.163.0"
        assert report["tools"]==["read_review","record_evidence","review_status","submit_review"]
        assert report["thread_id"] and report["metadata"]
        if mode=="cancel":
            assert report["scope_cancelled"] is True
    else:
        assert report["state"]=="ready" and report["invalid_refused"]


