"""Optional local stdio entry point. Importing this module needs only stdlib."""
from __future__ import annotations

import argparse
from contextlib import asynccontextmanager
from importlib import metadata
import json
import logging
from pathlib import Path
import sys
import uuid

PINS={"mcp":"2.3.0","dulwich":"1.2.17","pydantic":"2.14.1"}
DESCRIPTIONS={
    "open_review":"Pin the configured committed source/target refs and append a revision to their existing review series.",
    "read_review":"Read pinned manifests, source-tree entries, history descriptors or exact base64 artifact/evidence byte pages.",
    "record_evidence":"Store bounded evidence bytes or an unopened external descriptor; command/runtime/exit/origin claims stay unverified.",
    "submit_review":"Record a peer verdict. Cover every change and both old/new surfaces, and account once for every prior finding, including addressed findings and nits.",
    "review_status":"Recheck configured local refs and required objects; derive current collaborative peer status, which does not certify CI or authorize approval/merge.",
}


class StartupError(Exception):
    def __init__(self,code):
        self.code=code
        super().__init__(code)


def _require_extra():
    for name,version in PINS.items():
        try:
            installed=metadata.version(name)
        except metadata.PackageNotFoundError as error:
            raise StartupError("MISSING_EXTRA") from error
        if installed!=version:
            raise StartupError("UNSUPPORTED_EXTRA")


class _SafeHandler(logging.Handler):
    def emit(self,record):
        # Never format record.msg/args/exception: SDK parse failures may contain
        # entire incoming source/evidence bodies. stderr is diagnostic codes only.
        code="MCP_RUNTIME_ERROR" if record.levelno>=logging.ERROR else "MCP_RUNTIME_WARNING"
        try:
            sys.stderr.write(json.dumps({"code":code,"operation":"protocol",
                "correlation_id":uuid.uuid4().hex},separators=(",",":"))+"\n")
        except (OSError,ValueError):
            pass


def _safe_logging(*,root=False):
    names=("mcp.server","gauntlet.collaborative") if not root else ("",)
    for name in names:
        logger=logging.getLogger(name)
        logger.handlers=[_SafeHandler()]
        logger.setLevel(logging.WARNING)
        if name:
            logger.propagate=False
    if root:
        logging.captureWarnings(True)


def create_server(config):
    _require_extra()
    from mcp.server.lowlevel import Server
    from mcp.shared.exceptions import MCPError
    from mcp_types import CallToolResult,ListToolsResult,Tool,INVALID_PARAMS
    from pydantic import ConfigDict,ValidationError,create_model
    from .contracts import CoreError,Policy,REQUESTS,encode,validate_operator_config
    from .core import ROLE_TOOLS,ReviewCore
    from .source import GitSource
    from .store import Store

    config=validate_operator_config(config)
    _safe_logging()
    arguments={name:create_model(name+"Arguments",__config__=ConfigDict(strict=True,extra="forbid"),
                                 request=(model,...)) for name,model in REQUESTS.items()}

    @asynccontextmanager
    async def lifetime(_):
        with GitSource(config) as source,Store.open(config,source.repo_binding) as store:
            core=ReviewCore(config,source,store,Policy())
            try:
                yield core
            finally:
                core.close()

    async def list_tools(context,params):
        return ListToolsResult(tools=[Tool(name=name,description=DESCRIPTIONS[name],
            input_schema=arguments[name].model_json_schema()) for name in sorted(ROLE_TOOLS[config.role])])

    def result(core,payload):
        def build(value):
            return CallToolResult(content=[{"type":"text","text":encode(value).decode("utf-8")}],
                                  structured_content=value,is_error=not value["ok"])
        reply=build(payload)
        if len(reply.model_dump_json(by_alias=True,exclude_none=True).encode("utf-8"))>Policy().mcp_result_bytes:
            reply=build(core.error_response(CoreError("LIMIT_EXCEEDED",detail={"limit":"mcp_result_bytes"})))
        return reply

    async def call_tool(context,params):
        core=context.lifespan_context
        if params.name not in REQUESTS:
            raise MCPError(INVALID_PARAMS,"Unknown tool")
        try:
            parsed=arguments[params.name].model_validate(params.arguments,strict=True)
            # Only the five fixed names can reach getattr; args never select a
            # participant, role, path, executable, ref or Python method.
            payload=await getattr(core,params.name)(parsed.request)
        except ValidationError:
            payload=core.error_response(CoreError("INVALID_ARGUMENT",detail={"reason":"invalid_request"}))
        except CoreError as error:
            payload=core.error_response(error)
        except Exception:
            payload=core.error_response(CoreError("INTERNAL_ERROR",detail={"correlation_id":uuid.uuid4().hex}))
        return result(core,payload)

    return Server("gauntlet-collaborative",version=metadata.version("gauntlet-review"),
        description="Local collaborative-v1 review records and policy.",
        instructions="Native hosts own conversations and tool permissions. Peer completion records a fresh local review; it is not CI success, hermetic certification, human approval or merge permission.",
        lifespan=lifetime,on_list_tools=list_tools,on_call_tool=call_tool)


class _Parser(argparse.ArgumentParser):
    def error(self,message):
        # argparse's normal message includes the complete unknown argv values.
        raise StartupError("CONFIGURATION_ERROR")


def main(argv=None):
    _safe_logging(root=argv is None)
    try:
        parser=_Parser(prog="gauntlet-mcp",description="Local collaborative-v1 stdio review service")
        for name in ("repo","state-dir","repository-id","source-ref","target-ref","participant"):
            parser.add_argument("--"+name,required=True)
        parser.add_argument("--role",choices=("author","reviewer"),required=True)
        args=parser.parse_args(argv)
        _require_extra()
        import anyio
        from mcp.server.stdio import stdio_server
        from .contracts import OperatorConfig,validate_operator_config
        config=validate_operator_config(OperatorConfig(Path(args.repo),Path(args.state_dir),args.repository_id,
            args.source_ref.encode("utf-8","strict"),args.target_ref.encode("utf-8","strict"),args.participant,args.role))
        server=create_server(config)
        async def serve():
            async with stdio_server() as (read,write):
                await server.run(read,write,server.create_initialization_options())
        anyio.run(serve)
        return 0
    except SystemExit as error:
        return int(error.code or 0)
    except StartupError as error:
        if error.code=="MISSING_EXTRA":
            sys.stderr.write("MISSING_EXTRA: install the optional gauntlet-review[mcp] extra.\n")
        elif error.code=="UNSUPPORTED_EXTRA":
            sys.stderr.write("UNSUPPORTED_EXTRA: install the exact dependencies in gauntlet-review[mcp].\n")
        else:
            sys.stderr.write("CONFIGURATION_ERROR: invalid arguments; use --help.\n")
        return 2
    except KeyboardInterrupt:
        return 130
    except Exception as error:
        # Expected domain errors expose only their fixed code. Unexpected startup
        # errors get a correlation ID, never traceback/argv/source/credentials.
        contracts=sys.modules.get("gauntlet_review.collaborative.contracts")
        error_type=() if contracts is None else getattr(contracts,"CoreError",())
        code=error.code if isinstance(error,error_type) else "INTERNAL_ERROR"
        sys.stderr.write(json.dumps({"code":code,"operation":"startup","correlation_id":uuid.uuid4().hex},
                                    separators=(",",":"))+"\n")
        return 2
