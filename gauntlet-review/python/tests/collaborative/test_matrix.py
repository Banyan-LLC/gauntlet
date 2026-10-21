"""Controller failure propagation and preservation of earlier native receipts."""
import importlib.util
import json
from pathlib import Path
import sys


def test_later_failure_keeps_earlier_results_and_fails_matrix(tmp_path,monkeypatch):
    path=Path(__file__).resolve().parents[4]/"tests/run-collaborative-matrix.py"
    spec=importlib.util.spec_from_file_location("collaborative_matrix",path)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    calls=[]
    from collaborative_process import CommandFailure,CommandOutcome
    def run(argv,**kwargs):
        calls.append((argv,kwargs))
        outcome=CommandOutcome(completed=len(calls)==1,exit_code=0 if len(calls)==1 else 7,
                               tree_retired=True,receipt_path=tmp_path/f"receipt-{len(calls)}.json")
        outcome.receipt_path.write_text('{}')
        if not outcome.completed:
            raise CommandFailure(outcome)
        return outcome
    monkeypatch.setattr(module,"run_case",run)
    assert module.run_suites(tmp_path,base_only=False)==1
    saved=json.loads((tmp_path/"suite-results.json").read_text())
    assert [r["exit_code"] for r in saved]==[0,7]
    assert all(Path(r["receipt"]).exists() for r in saved)
    assert all(c[1]["deadline_seconds"]==900 for c in calls)
    assert all(c[0][0]==sys.executable for c in calls)


def test_optional_matrix_separates_adapter_and_native_smoke_from_legacy(tmp_path,monkeypatch):
    path=Path(__file__).resolve().parents[4]/"tests/run-collaborative-matrix.py"
    spec=importlib.util.spec_from_file_location("sdk_matrix",path)
    module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    from collaborative_process import CommandOutcome
    calls=[]
    def run(argv,**kwargs):
        calls.append(argv)
        return CommandOutcome(completed=True,exit_code=0,tree_retired=True,receipt_path=tmp_path/f"{len(calls)}.json")
    monkeypatch.setattr(module,"run_case",run)
    assert module.run_suites(tmp_path,base_only=False)==0
    saved=json.loads((tmp_path/"suite-results.json").read_text())
    assert [item["suite"] for item in saved]==["collaborative","codex_bridge","legacy"]
    assert "tests/codex_bridge" in calls[1]
    assert "--ignore=tests/codex_bridge" in calls[2]
