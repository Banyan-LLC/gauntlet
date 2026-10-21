"""Owned scenarios and fault checkpoints; never installed with the product."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import time


def main():
    from collaborative_process import ExpectedExit, checkpoint, owner_context, run_case
    scenario = sys.argv[1]
    if scenario == "success":
        os.write(1, b"hello\x00\xff\n")
        os.write(2, b"diagnostic\n")
    elif scenario.startswith("crash"):
        if scenario == "crash":
            checkpoint("before-commit")
        os._exit(73)
    elif scenario == "sleep":
        time.sleep(120)
    elif scenario in {"stdout-overflow", "stderr-overflow", "control-overflow", "combined-overflow"}:
        if scenario == "control-overflow":
            for _ in range(300):
                checkpoint("x" * 800)
        elif scenario == "combined-overflow":
            os.write(1, b"a" * (4 * 1024 * 1024))
            os.write(2, b"b" * (4 * 1024 * 1024))
            checkpoint("over-combined-limit")
        else:
            fd = 1 if scenario.startswith("stdout") else 2
            for _ in range(2048):
                os.write(fd, b"x" * 4096)
    elif scenario.startswith("descendant-"):
        channel = scenario.split("-", 1)[1]
        kwargs = {name: (None if name == channel else subprocess.DEVNULL)
                  for name in ("stdin", "stdout", "stderr")}
        subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"], **kwargs)
    elif scenario == "stdin-closed":
        os.close(0)
        time.sleep(0.2)
    elif scenario == "context":
        print(json.dumps(owner_context()))
    elif scenario.startswith("nested-"):
        parent = owner_context()
        environment = dict(os.environ)
        if scenario == "nested-fresh-session":
            environment["GAUNTLET_TEST_FRESH_SESSION"] = "1"
        elif scenario == "nested-context-mismatch":
            environment["GAUNTLET_TEST_OWNER"] = "{}"
        elif scenario == "nested-budget":
            for _ in range(3):
                run_case([sys.executable, "-c", "import os; os.write(1,b'x'*(3*1024*1024))"],
                         cwd=Path(__file__).parent, environment=environment,
                         deadline_seconds=999, expected=ExpectedExit())
            print("continued")
            return
        command = "context" if scenario == "nested-success" else "crash-no-checkpoint"
        outcome = run_case([sys.executable, __file__, command], cwd=Path(__file__).parent,
                           environment=environment, deadline_seconds=999,
                           expected=ExpectedExit())
        child = json.loads(outcome.stdout.prefix)
        print(json.dumps({"token": parent["token"], "child_token": child["token"],
                          "deadline": parent["deadline"], "child_deadline": child["deadline"],
                          "fresh_owner": outcome.fresh_owner}))
        if scenario == "nested-failure":
            print("continued")
    elif scenario == "matrix-expiry":
        for _ in range(2):
            subprocess.Popen([sys.executable, "-c",
                              "import os,subprocess,sys,time; "
                              "subprocess.Popen([sys.executable,'-c','import time; time.sleep(120)']); "
                              "os.write(1,b'host-ready\\n'); time.sleep(120)"])
        time.sleep(120)
    elif scenario.startswith("mcp-"):
        import anyio
        from mcp import Client
        from collaborative_process import OwnedTransport

        async def exercise():
            if scenario == "mcp-real-expiry":
                import tempfile
                from dulwich.repo import Repo
                from gauntlet_review.collaborative.contracts import OperatorConfig
                from collaborative_scenario import server_args
                root=Path(tempfile.mkdtemp(prefix="real-expiry-",dir=owner_context()["receipts"]))
                repo,state=root/"repo",root/"state"
                repo.mkdir(); state.mkdir(mode=0o700)
                Repo.init(str(repo)).close()
                config=OperatorConfig(repo,state,"expiry",b"refs/heads/topic",b"refs/heads/main","author","author")
                async with Client(OwnedTransport([sys.executable,*server_args(config,"author")],cwd=root)) as first:
                    await first.list_tools()
                    os.write(1,b"host-ready\n")
                    async with Client(OwnedTransport([sys.executable,*server_args(config,"reviewer")],cwd=root)) as second:
                        await second.list_tools()
                        os.write(1,b"host-ready\n")
                        # Deliberate pipe-holding descendants remain inside the
                        # same native owner; production peers spawn no children.
                        subprocess.Popen([sys.executable,"-c",
                            "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c','import time; time.sleep(120)']); time.sleep(120)"])
                        await anyio.sleep(120)
                return
            if scenario == "mcp-sibling-closure":
                first_ready, second_ready, first_closed = (anyio.Event() for _ in range(3))
                argv = [sys.executable, str(Path(__file__).with_name("collaborative_echo.py"))]
                async def first():
                    async with Client(OwnedTransport(argv, cwd=Path(__file__).parent)) as client:
                        await client.list_tools()
                        first_ready.set()
                        await second_ready.wait()
                    first_closed.set()
                async def second():
                    await first_ready.wait()
                    async with Client(OwnedTransport(argv, cwd=Path(__file__).parent)) as client:
                        await client.list_tools()
                        second_ready.set()
                        await first_closed.wait()
                        assert (await client.list_tools()).tools[0].name == "probe-tool"
                async with anyio.create_task_group() as group:
                    group.start_soon(first)
                    group.start_soon(second)
                print("both-peers-closed")
                return
            if scenario == "mcp-frame-overflow":
                argv = [sys.executable, "-c", "import os; os.write(1,b'x'*(512*1024+1)+b'\\n')"]
            else:
                argv = [sys.executable, str(Path(__file__).with_name("collaborative_echo.py"))]
            async with Client(OwnedTransport(argv, cwd=Path(__file__).parent),
                              raise_exceptions=True) as client:
                result = await client.list_tools()
                print(result.model_dump_json(by_alias=True))
        anyio.run(exercise)
    else:
        raise ValueError(scenario)


if __name__ == "__main__":
    main()
