from dataclasses import replace
import json
import logging
from pathlib import Path

import jsonschema
import pytest

from gauntlet_review.collaborative.contracts import CoreError,encode


@pytest.mark.anyio
@pytest.mark.parametrize("role",["author","reviewer"])
async def test_registered_tools_are_role_specific_and_schemas_are_resolvable(cfg,git_fixture,role):
    from mcp import Client
    from gauntlet_review.collaborative.server import create_server
    git_fixture.pair({}, {b"file":(0o100644,b"one")})
    async with Client(create_server(replace(cfg,role=role)),raise_exceptions=True) as client:
        result=await client.list_tools()
        names={tool.name for tool in result.tools}
        assert names == {"read_review","record_evidence","review_status", "open_review" if role=="author" else "submit_review"}
        for tool in result.tools:
            schema=tool.input_schema
            jsonschema.Draft202012Validator.check_schema(schema)
            assert schema["type"] == "object" and schema["required"] == ["request"]
            assert schema["additionalProperties"] is False
            assert set(schema["properties"]) == {"request"}
            text=encode(schema).decode("utf-8")
            assert '"repo_path"' not in text and '"participant"' not in text and '"role"' not in text
            if tool.name=="review_status":
                jsonschema.validate({"request":{}},schema)
                with pytest.raises(jsonschema.ValidationError):
                    jsonschema.validate({"request":{"approved":True}},schema)


@pytest.mark.anyio
async def test_sdk_call_returns_canonical_text_structured_content_and_domain_errors(cfg,git_fixture):
    from mcp import Client
    from gauntlet_review.collaborative.server import create_server
    git_fixture.pair({}, {b"file":(0o100644,b"one")})
    async with Client(create_server(cfg),raise_exceptions=True) as client:
        status=await client.call_tool("review_status",{"request":{}})
        assert not status.is_error and status.structured_content["result"]["series"] is None
        assert status.content[0].text == encode(status.structured_content).decode("utf-8")
        opened=await client.call_tool("open_review",{"request":{"key":"initial","expected_version":0}})
        assert opened.structured_content["ok"] and not opened.is_error
        for args in ({"request":{"key":"private-source-content","expected_version":True}},
                     {"request":{"key":"x","expected_version":1,"role":"reviewer"}},
                     {"request":{},"role":"reviewer"},{}):
            result=await client.call_tool("open_review",args)
            assert result.is_error and result.structured_content["error"]["code"] == "INVALID_ARGUMENT"
            assert "private-source-content" not in result.content[0].text
        forbidden=await client.call_tool("submit_review",{"request":{
            "key":"peer","expected_version":1,**{k:opened.structured_content[k] for k in ("review_id","revision_id","snapshot_digest")},
            "verdict":"approve","summary":"reviewed","recommendations":[],"carryover":[],
            "coverage_digest":opened.structured_content["snapshot_digest"],"coverage":[]}})
        assert forbidden.is_error and forbidden.structured_content["error"]["code"] == "FORBIDDEN"


@pytest.mark.anyio
async def test_sdk_unknown_protocol_methods_remain_protocol_errors(cfg,git_fixture):
    from mcp import Client
    from mcp.shared.exceptions import MCPError
    from mcp_types import Request,EmptyResult
    from gauntlet_review.collaborative.server import create_server
    git_fixture.pair({}, {b"file":(0o100644,b"one")})
    async with Client(create_server(cfg),raise_exceptions=True) as client:
        with pytest.raises(MCPError) as error:
            await client.session.send_request(Request(method="private/unregistered",params=None),EmptyResult)
        assert error.value.code == -32601
        with pytest.raises(MCPError) as error:
            await client.session.send_request(Request(method="tools/call",params={"name":"review_status","arguments":"malformed"}),EmptyResult)
        assert error.value.code == -32602


@pytest.mark.anyio
async def test_connection_shutdown_closes_real_core_resources(cfg,git_fixture,monkeypatch):
    from mcp import Client
    from gauntlet_review.collaborative import core as module
    from gauntlet_review.collaborative.server import create_server
    captured=[]
    original=module.ReviewCore
    class CapturedCore(original):
        def __init__(self,*args,**kwargs):
            super().__init__(*args,**kwargs)
            captured.append(self)
    monkeypatch.setattr(module,"ReviewCore",CapturedCore)
    git_fixture.pair({}, {b"file":(0o100644,b"one")})
    async with Client(create_server(cfg),raise_exceptions=True) as client:
        assert (await client.call_tool("review_status",{"request":{}})).structured_content["ok"]
        assert len(captured)==1 and not captured[0].source.closed and not captured[0].store.closed
    assert captured[0].source.closed and captured[0].store.closed


def test_invalid_cli_flags_and_relative_paths_fail_before_store_open(cfg,monkeypatch,capsys):
    from gauntlet_review.collaborative import server
    def forbidden(*args,**kwargs):
        raise AssertionError("opened server before validating arguments")
    monkeypatch.setattr(server,"create_server",forbidden)
    flags=["--repo",str(cfg.repo_path),"--state-dir",str(cfg.state_dir),"--repository-id","fixture",
           "--source-ref","refs/heads/topic","--target-ref","refs/heads/main","--participant","author","--role","author"]
    assert server.main(flags+["--port","private-source-content"]) == 2
    relative=flags.copy()
    relative[1]="relative"
    assert server.main(relative) == 2
    captured=capsys.readouterr()
    assert captured.out == "" and "private-source-content" not in captured.err
    assert "Traceback" not in captured.err


def test_sdk_diagnostics_do_not_log_untrusted_exception_bodies(cfg,capsys):
    from gauntlet_review.collaborative.server import create_server
    create_server(cfg)
    try:
        raise ValueError("private-source-content")
    except ValueError:
        logging.getLogger("mcp.server.stdio").exception("private-source-content")
    captured=capsys.readouterr()
    assert "private-source-content" not in captured.out+captured.err
    assert "MCP_RUNTIME_ERROR" in captured.err


def test_server_rejects_relative_configuration_before_sdk_lifespan(cfg):
    from gauntlet_review.collaborative.server import create_server
    with pytest.raises(CoreError) as error:
        create_server(replace(cfg,state_dir=Path("relative")))
    assert error.value.code == "CONFIGURATION_ERROR"


def test_broken_optional_import_cannot_break_safe_startup_diagnostics(cfg,monkeypatch,capsys):
    import builtins
    from gauntlet_review.collaborative.server import main
    original=builtins.__import__
    def broken(name,globals=None,locals=None,fromlist=(),level=0):
        if name=="anyio" or (name=="contracts" and level==1):
            raise ImportError("private-source-content")
        return original(name,globals,locals,fromlist,level)
    monkeypatch.setattr(builtins,"__import__",broken)
    flags=["--repo",str(cfg.repo_path),"--state-dir",str(cfg.state_dir),"--repository-id","fixture",
           "--source-ref","refs/heads/topic","--target-ref","refs/heads/main","--participant","author","--role","author"]
    assert main(flags) == 2
    captured=capsys.readouterr()
    assert captured.out == "" and "INTERNAL_ERROR" in captured.err
    assert "private-source-content" not in captured.err and "Traceback" not in captured.err


@pytest.mark.anyio
async def test_sdk_cancellation_before_commit_rolls_back_without_success(cfg,git_fixture,monkeypatch):
    import anyio
    from mcp import Client
    from gauntlet_review.collaborative.core import ReviewCore
    from gauntlet_review.collaborative.server import create_server
    ready=anyio.Event()
    done=anyio.Event()
    scopes=[]
    answers=[]
    count=0
    async def checkpoint():
        nonlocal count
        count+=1
        if count==3:
            ready.set()
            await anyio.sleep_forever()
    monkeypatch.setattr(ReviewCore,"_checkpoint",staticmethod(checkpoint))
    git_fixture.pair({}, {b"file":(0o100644,b"one")})
    async with Client(create_server(cfg),raise_exceptions=True) as client:
        async def caller():
            with anyio.CancelScope() as scope:
                scopes.append(scope)
                answers.append(await client.call_tool("open_review",{"request":{"key":"cancelled","expected_version":0}}))
            done.set()
        async with anyio.create_task_group() as group:
            group.start_soon(caller)
            with anyio.fail_after(5):
                await ready.wait()
                scopes[0].cancel()
                await done.wait()
        assert not answers
        response=await client.call_tool("review_status",{"request":{}})
        assert response.structured_content["store_version"] == 0
        assert response.structured_content["result"]["series"] is None
