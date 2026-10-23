"""Optional stdio host. Import is safe when the optional SDK is absent."""
from __future__ import annotations

import argparse
from contextlib import asynccontextmanager
from importlib import metadata
import json
from pathlib import Path
import sys
import uuid

from gauntlet_review.collaborative.server import StartupError,_Parser,_safe_logging

PINS={"mcp":"2.3.0","dulwich":"1.2.17","pydantic":"2.14.1",
    "openai-codex":"0.163.0","openai-codex-cli-bin":"0.163.0"}


def _require_extra():
    for name,version in PINS.items():
        try:
            installed=metadata.version(name)
        except metadata.PackageNotFoundError as error:
            raise StartupError("MISSING_EXTRA") from error
        if installed!=version:
            raise StartupError("UNSUPPORTED_EXTRA")


def SdkConversation(config):
    # Lazy import also makes the no-model status path independent of SDK startup.
    from .sdk import SdkConversation as Conversation
    return Conversation(config)


def create_server(config):
    _require_extra()
    from mcp.server.lowlevel import Server
    from mcp.shared.exceptions import MCPError
    from mcp_types import ListToolsResult,Tool,INVALID_PARAMS
    from .engine import Bridge,BridgeError,ReviewRequest,mcp_result,validate_config
    config=validate_config(config)
    _safe_logging()

    @asynccontextmanager
    async def lifetime(_):
        bridge=Bridge(config,SdkConversation(config))
        try:
            yield bridge
        finally:
            await bridge.close()

    async def list_tools(context,params):
        return ListToolsResult(tools=[
            Tool(name="codex_status",description="Get this adapter instance, owned thread and state without starting a model turn.",
                input_schema={"type":"object","properties":{},"additionalProperties":False}),
            Tool(name="codex_review",description="Run or exactly replay one Codex peer turn. Echo the current instance and owned thread. After restart, stop and explicitly begin a fresh conversation that rereads all existing review history and findings. Never silently replay uncertain turns. Completion comes only from fresh core review_status.",
                input_schema=ReviewRequest.model_json_schema())])

    async def call_tool(context,params):
        bridge=context.lifespan_context
        if params.name=="codex_status":
            payload=bridge.status() if params.arguments in ({},None) else bridge.error_response(BridgeError("INVALID_ARGUMENT"))
        elif params.name=="codex_review":
            payload=await bridge.call(params.arguments)
        else:
            raise MCPError(INVALID_PARAMS,"Unknown tool")
        return mcp_result(payload)

    return Server("gauntlet-codex",version=metadata.version("gauntlet-review"),
        instructions="One SDK conversation per process. Native authentication and runtime lifecycle remain native-host responsibilities. Preserve existing core history after restart. No automatic retry, approval or merge.",
        lifespan=lifetime,on_list_tools=list_tools,on_call_tool=call_tool)


def main(argv=None):
    _safe_logging(root=argv is None)
    try:
        parser=_Parser(prog="gauntlet-codex",description="SDK-backed local stdio conversation host")
        for name in ("repo","state-dir","repository-id","source-ref","target-ref","participant"):
            parser.add_argument("--"+name,required=True)
        parser.add_argument("--model")
        parser.add_argument("--timeout-seconds",type=int,default=600)
        args=parser.parse_args(argv)
        _require_extra()
        import anyio
        from mcp.server.stdio import stdio_server
        from gauntlet_review.collaborative.contracts import OperatorConfig
        from .engine import BridgeConfig
        config=BridgeConfig(OperatorConfig(Path(args.repo),Path(args.state_dir),args.repository_id,
            args.source_ref.encode("utf-8","strict"),args.target_ref.encode("utf-8","strict"),args.participant,"reviewer"),
            model=args.model,timeout_seconds=args.timeout_seconds)
        server=create_server(config)
        async def serve():
            async with stdio_server() as (read,write):
                await server.run(read,write,server.create_initialization_options())
        anyio.run(serve)
        return 0
    except SystemExit as error:
        return int(error.code or 0)
    except StartupError as error:
        sys.stderr.write(error.code+": install the exact gauntlet-review[codex] dependencies or check --help.\n")
        return 2
    except KeyboardInterrupt:
        return 130
    except Exception:
        sys.stderr.write(json.dumps({"code":"CONFIGURATION_OR_RUNTIME_ERROR","correlation_id":uuid.uuid4().hex},separators=(",",":"))+"\n")
        return 2
