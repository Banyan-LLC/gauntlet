"""Actual SDK streams/processes; the external suite owner retains every child."""
import json
import os
from pathlib import Path
import sys

import pytest

SUPPORT=Path(__file__).resolve().parents[4]/"tests"/"support"
sys.path.insert(0,str(SUPPORT))
from collaborative_process import ExpectedExit,run_case


def execute(cfg,scenario,*,expected=None):
    return run_case([sys.executable,str(SUPPORT/"collaborative_scenario.py"),scenario,
                     str(cfg.repo_path),str(cfg.state_dir)],cwd=SUPPORT,
                    environment=dict(os.environ),deadline_seconds=90,
                    expected=expected or ExpectedExit())


def test_two_stdio_hosts_keep_history_source_and_evidence_after_restart(cfg,git_fixture):
    git_fixture.pair({b"file":(0o100644,b"old")},{b"file":(0o100644,b"one")})
    result=execute(cfg,"two-hosts")
    assert result.completed and result.tree_retired and result.expectation_match
    report=json.loads(result.stdout.prefix)
    assert len(set(report["pids"]))==4
    assert report["status"]=="peer_complete" and report["events"]==5
    assert report["head_drift"]==report["target_drift"]=="stale"


@pytest.mark.parametrize("point",["before-commit","after-commit"])
def test_real_process_crash_around_commit_is_atomic_and_exactly_recoverable(cfg,git_fixture,point):
    git_fixture.pair({}, {b"file":(0o100644,b"one")})
    crashed=execute(cfg,point,expected=ExpectedExit(73,point))
    assert crashed.completed and crashed.exit_code==73 and crashed.tree_retired
    recovered=execute(cfg,"recover-"+point)
    assert recovered.completed
    report=json.loads(recovered.stdout.prefix)
    assert report["before"]==(0 if point=="before-commit" else 1)
    assert report["after"]==report["events"]==1


def test_raw_malformed_json_and_unknown_protocol_are_safe(cfg,git_fixture):
    git_fixture.pair({}, {b"file":(0o100644,b"one")})
    result=execute(cfg,"raw-protocol")
    assert result.completed and json.loads(result.stdout.prefix)["safe"]
