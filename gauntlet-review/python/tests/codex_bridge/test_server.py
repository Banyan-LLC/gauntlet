import json
from dataclasses import replace

import pytest
pytest.importorskip("openai_codex")
from mcp import Client
from mcp.shared.exceptions import MCPError

from gauntlet_review.codex_bridge import server
from gauntlet_review.codex_bridge.engine import PeerReply

pytestmark=pytest.mark.anyio


class Peer:
    def __init__(self,config):
        self.calls=0; self.closed=False

    async def run(self,prompt):
        self.calls+=1
        return PeerReply("thread-1",f"turn-{self.calls}","complete")

    async def close(self):
        self.closed=True


async def test_two_strict_tools_status_no_native_turn_and_exact_result_parity(config,monkeypatch):
    peers=[]
    def create(cfg):
        peer=Peer(cfg); peers.append(peer); return peer
    monkeypatch.setattr(server,"SdkConversation",create)
    async with Client(server.create_server(config),raise_exceptions=True) as client:
        tools=(await client.list_tools()).tools
        assert {t.name for t in tools}=={"codex_status","codex_review"}
        assert all(t.input_schema["additionalProperties"] is False for t in tools)
        status=(await client.call_tool("codex_status",{})).structured_content
        assert status["state"]=="ready" and peers[0].calls==0
        args={"instance_id":status["instance_id"],"key":"first","prompt":"review","expected_thread_id":None}
        first=await client.call_tool("codex_review",args)
        assert first.structured_content["ok"] and json.loads(first.content[0].text)==first.structured_content
        assert (await client.call_tool("codex_review",args)).structured_content==first.structured_content
        assert peers[0].calls==1
        for bad in ({**args,"model":"private-sdk-detail"},{**args,"prompt":False},{}):
            result=await client.call_tool("codex_review",bad)
            assert result.is_error and result.structured_content["error"]["code"]=="INVALID_ARGUMENT"
            assert "private-sdk-detail" not in result.content[0].text
        result=await client.call_tool("codex_status",{"extra":"private-sdk-detail"})
        assert result.is_error and "private-sdk-detail" not in result.content[0].text
        with pytest.raises(MCPError):
            await client.call_tool("unknown",{})
    assert peers[0].closed


async def test_status_shows_the_extended_timeout_only_when_opted_in(config,monkeypatch):
    monkeypatch.setattr(server,"SdkConversation",Peer)
    extended=replace(config,timeout_seconds=5400,extended_timeout=True)
    for cfg,block in ((config,None),(extended,{"timeout_seconds":5400,"max_seconds":7200})):
        async with Client(server.create_server(cfg),raise_exceptions=True) as client:
            status=(await client.call_tool("codex_status",{})).structured_content
        assert set(status)=={"ok","instance_id","thread_id","state"}|({"extended_timeout"} if block else set())
        assert status.get("extended_timeout")==block


def _cli(config,*extra):
    operator=config.operator
    return ["--repo",str(operator.repo_path),"--state-dir",str(operator.state_dir),
        "--repository-id",operator.repository_id,"--source-ref",operator.source_ref.decode(),
        "--target-ref",operator.target_ref.decode(),"--participant",operator.participant,*extra]


@pytest.mark.parametrize("extra, expected",[
    (["--timeout-seconds","5400"],{"code":"TIMEOUT_OUT_OF_RANGE","accepted":{"min":10,"max":1800},
        "opt_in":{"flag":"--allow-extended-timeout","max":7200}}),
    (["--timeout-seconds","1801"],{"code":"TIMEOUT_OUT_OF_RANGE","accepted":{"min":10,"max":1800},
        "opt_in":{"flag":"--allow-extended-timeout","max":7200}}),
    (["--timeout-seconds","7201","--allow-extended-timeout"],{"code":"TIMEOUT_OUT_OF_RANGE","accepted":{"min":10,"max":7200}}),
    (["--timeout-seconds","9"],{"code":"TIMEOUT_OUT_OF_RANGE","accepted":{"min":10,"max":1800}}),
])
def test_out_of_range_timeout_refuses_at_startup_and_says_how_to_opt_in(config,monkeypatch,capsys,extra,expected):
    def create(cfg):
        raise AssertionError("refused before building the server")
    monkeypatch.setattr(server,"create_server",create)
    assert server.main(_cli(config,*extra))==2
    assert json.loads(capsys.readouterr().err)==expected


@pytest.mark.parametrize("extra, timeout, extended",[
    ([],600,False),
    (["--timeout-seconds","1800"],1800,False),
    (["--timeout-seconds","5400","--allow-extended-timeout"],5400,True),
    (["--timeout-seconds","7200","--allow-extended-timeout"],7200,True),
])
def test_cli_passes_the_timeout_and_override_to_the_adapter(config,monkeypatch,extra,timeout,extended):
    seen={}
    def create(cfg):
        seen["config"]=cfg
        raise SystemExit(0)
    monkeypatch.setattr(server,"create_server",create)
    assert server.main(_cli(config,*extra))==0
    assert (seen["config"].timeout_seconds,seen["config"].extended_timeout)==(timeout,extended)


@pytest.mark.parametrize("distribution",["openai-codex","openai-codex-cli-bin"])
@pytest.mark.parametrize("missing",[False,True])
async def test_wrong_or_missing_sdk_pin_refuses_before_native_configuration(config,monkeypatch,distribution,missing):
    from importlib import metadata
    original=metadata.version
    def version(name):
        if name==distribution:
            if missing:
                raise metadata.PackageNotFoundError(name)
            return "0.0.0"
        return original(name)
    monkeypatch.setattr(metadata,"version",version)
    with pytest.raises(server.StartupError):
        server.create_server(config)


async def test_actual_mcp_cap_applies_to_success_errors_and_replays(config,monkeypatch):
    class LargePeer(Peer):
        async def run(self,prompt):
            self.calls+=1
            return PeerReply("thread-1","turn-1", "\0"*30000 if prompt=="large" else '"\\😀'*4000)
    monkeypatch.setattr(server,"SdkConversation",LargePeer)
    async with Client(server.create_server(config),raise_exceptions=True) as client:
        status=(await client.call_tool("codex_status",{})).structured_content
        first={"instance_id":status["instance_id"],"key":"first","prompt":"okay","expected_thread_id":None}
        good=await client.call_tool("codex_review",first)
        replay=await client.call_tool("codex_review",first)
        assert good.structured_content["ok"] and replay.structured_content==good.structured_content
        bad={**first,"key":"second","prompt":"large","expected_thread_id":"thread-1"}
        error=await client.call_tool("codex_review",bad)
        assert error.is_error and error.structured_content["error"]["code"]=="LIMIT_EXCEEDED"
        again=await client.call_tool("codex_review",bad)
        assert again.structured_content==error.structured_content
        for result in (good,replay,error,again):
            assert len(result.model_dump_json(by_alias=True,exclude_none=True).encode("utf-8"))<=262144
