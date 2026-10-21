"""Model-free real SDK/runtime and adapter probes, inside the external owner."""
from __future__ import annotations

import argparse
import asyncio
from importlib import metadata
import json
import os
from pathlib import Path
import sys

from collaborative_process import OwnedTransport,checkpoint,owner_context


async def probe(operator,mode):
    from openai_codex import CodexConfig
    from openai_codex.async_client import AsyncCodexClient
    from openai_codex.generated.v2_all import ListMcpServerStatusParams,ListMcpServerStatusResponse,ThreadStartParams
    from gauntlet_review.codex_bridge.engine import BridgeConfig
    from gauntlet_review.codex_bridge.sdk import reviewer_config
    report=None
    try:
        async with AsyncCodexClient(CodexConfig(cwd=str(operator.repo_path))) as client:
            initialized=await client.initialize()
            started=await client.thread_start(ThreadStartParams.model_validate({
                "cwd":str(operator.repo_path),"approvalPolicy":"never","sandbox":"read-only",
                "config":reviewer_config(BridgeConfig(operator))}))
            params=ListMcpServerStatusParams(thread_id=started.thread.id,server_name="gauntlet-reviewer",limit=100)
            inventory=await client.request("mcpServerStatus/list",params.model_dump(mode="json",by_alias=True),
                response_model=ListMcpServerStatusResponse)
            assert inventory.next_cursor is None
            selected=[server for server in inventory.data if server.name=="gauntlet-reviewer"]
            assert len(selected)==1 and selected[0].tools_error is None
            tools=sorted(selected[0].tools)
            assert tools==["read_review","record_evidence","review_status","submit_review"],tools
            report={"sdk":metadata.version("openai-codex"),"runtime":metadata.version("openai-codex-cli-bin"),
                "metadata":initialized.model_dump(mode="json",exclude_none=True),"thread_id":started.thread.id,
                "tools":tools,"model_calls":0}
            if mode=="expiry":
                print("sdk-ready",flush=True)
                checkpoint("sdk-ready")
                await asyncio.Event().wait()
            if mode=="cancel":
                # Cancel the scope owning the actual native client. Its public
                # __aexit__ receives CancelledError and must attempt SDK close.
                asyncio.current_task().cancel()
                await asyncio.sleep(0)
                raise AssertionError("scope cancellation was not delivered")
    except asyncio.CancelledError:
        if mode!="cancel" or report is None:
            raise
        report["scope_cancelled"]=True
    return report


async def stdio(operator):
    from mcp import Client
    argv=[sys.executable,"-m","gauntlet_review.codex_bridge","--repo",str(operator.repo_path),
        "--state-dir",str(operator.state_dir),"--repository-id",operator.repository_id,
        "--source-ref",operator.source_ref.decode(),"--target-ref",operator.target_ref.decode(),
        "--participant",operator.participant]
    async with Client(OwnedTransport(argv,cwd=operator.repo_path),raise_exceptions=True) as client:
        assert {tool.name for tool in (await client.list_tools()).tools}=={"codex_status","codex_review"}
        status=(await client.call_tool("codex_status",{})).structured_content
        assert status["state"]=="ready" and status["thread_id"] is None
        bad=await client.call_tool("codex_review",{"prompt":"private-smoke-body","model":"forbidden"})
        assert bad.is_error and bad.structured_content["error"]["code"]=="INVALID_ARGUMENT"
        assert "private-smoke-body" not in bad.content[0].text
        assert (await client.call_tool("codex_status",{})).structured_content==status
        return {"model_calls":0,"state":status["state"],"invalid_refused":True}


def main():
    owner_context()  # Refuse execution outside native test custody.
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo",type=Path,required=True)
    parser.add_argument("--state",type=Path,required=True)
    parser.add_argument("--mode",choices=("smoke","stdio","cancel","expiry"),default="smoke")
    args=parser.parse_args()
    from gauntlet_review.collaborative.contracts import OperatorConfig,validate_operator_config
    operator=validate_operator_config(OperatorConfig(args.repo,args.state,"fixture",b"refs/heads/topic",
        b"refs/heads/main","peer","reviewer"))
    report=asyncio.run(stdio(operator) if args.mode=="stdio" else probe(operator,args.mode))
    print(json.dumps(report,separators=(",",":")),flush=True)
    return 0


if __name__=="__main__":
    raise SystemExit(main())
