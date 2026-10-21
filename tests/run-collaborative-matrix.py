"""External Python-only verification controller; no model or API credentials."""
from __future__ import annotations

import argparse
import hashlib
from importlib import metadata,util
import json
import os
from pathlib import Path
import platform
import re
import sqlite3
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
SUPPORT=ROOT/"tests/support"
sys.path.insert(0,str(SUPPORT))
from collaborative_process import CommandFailure,ExpectedExit,run_case


def write_once(path,value):
    with path.open("x",encoding="utf-8",newline="\n") as stream:
        json.dump(value,stream,ensure_ascii=True,allow_nan=False,indent=2)
        stream.write("\n")


def run_suites(receipts,*,base_only):
    package=ROOT/"gauntlet-review/python"
    suites=[("base",["tests","--ignore=tests/collaborative"])] if base_only else [
        ("collaborative",["tests/collaborative"]),("legacy",["tests","--ignore=tests/collaborative"])]
    results=[]
    status=0
    for name,paths in suites:
        environment=dict(os.environ,PYTHONDONTWRITEBYTECODE="1",GAUNTLET_TEST_RECEIPTS=str(receipts))
        if base_only:
            environment["GAUNTLET_EXPECT_BASE_ONLY"]="1"
        else:
            environment.pop("GAUNTLET_EXPECT_BASE_ONLY",None)
        try:
            outcome=run_case([sys.executable,"-m","pytest",*paths,"-q","-o","addopts=","--tb=short","--maxfail=5"],
                cwd=package,environment=environment,deadline_seconds=900,expected=ExpectedExit())
        except CommandFailure as error:
            outcome=error.outcome
        results.append({"suite":name,"completed":outcome.completed,"exit_code":outcome.exit_code,
                        "tree_retired":outcome.tree_retired,"receipt":str(outcome.receipt_path)})
        print(f"{name}: completed={outcome.completed} exit={outcome.exit_code} retired={outcome.tree_retired}",flush=True)
        sys.stdout.buffer.write(outcome.stdout.prefix[-16384:])
        sys.stderr.buffer.write(outcome.stderr.prefix[-16384:])
        if not outcome.completed:
            status=1
            break
    write_once(receipts/"suite-results.json",results)
    return status


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipts",required=True,type=Path)
    parser.add_argument("--source-revision",required=True)
    parser.add_argument("--base-only",action="store_true")
    args=parser.parse_args(argv)
    if os.environ.get("GAUNTLET_TEST_OWNER"):
        parser.error("matrix must be the external controller; fatal probes own their workers")
    if not args.receipts.is_absolute() or not re.fullmatch(r"[0-9a-f]{40}",args.source_revision):
        parser.error("absolute receipt directory and full source revision required")
    args.receipts.mkdir(parents=True,exist_ok=False)
    os.environ["PYTHONDONTWRITEBYTECODE"]="1"
    os.environ["GAUNTLET_PROBE_ARCHIVE"]=str(args.receipts/"custody")
    write_once(args.receipts/"environment.json",{
        "source_revision":args.source_revision,"python":sys.version,"executable":sys.executable,
        "platform":platform.platform(),"sqlite":sqlite3.sqlite_version,"base_only":args.base_only,
        "dependencies":dict(sorted((d.metadata["Name"],d.version) for d in metadata.distributions())),
        "source_files":{str(p.relative_to(ROOT)).replace("\\","/"):hashlib.sha256(p.read_bytes()).hexdigest()
            for directory in (ROOT/"gauntlet-review/python",ROOT/"tests/support",ROOT/".github/workflows")
            for p in sorted(directory.rglob("*")) if p.is_file() and p.suffix in (".py",".toml",".yml")}})
    spec=util.spec_from_file_location("custody_probes",SUPPORT/"test_collaborative_process.py")
    module=util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # Run probe assertions in THIS controller. Every fatal worker has its own
    # native owner, rather than recursively supervising its external controller.
    with (args.receipts/"custody-probes.log").open("x",encoding="utf-8") as stream:
        result=unittest.TextTestRunner(stream=stream,verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(module))
    write_once(args.receipts/"custody-results.json",{"successful":result.wasSuccessful(),
        "run":result.testsRun,"skipped":[{"test":str(t),"reason":r} for t,r in result.skipped]})
    if not result.wasSuccessful():
        print("Native custody capability probes failed; spawned acceptance tests were not started.",file=sys.stderr)
        return 1
    return run_suites(args.receipts,base_only=args.base_only)


if __name__=="__main__":
    raise SystemExit(main())
