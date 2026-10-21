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
