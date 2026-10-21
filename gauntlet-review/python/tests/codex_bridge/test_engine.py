"""Consumer contracts for admission, exact replay and uncertain native failures."""
import asyncio
from dataclasses import replace
import json

import pytest

from gauntlet_review.codex_bridge.engine import Bridge,BridgeConfig,BridgeError,PeerReply

pytestmark=pytest.mark.anyio


class Conversation:
    def __init__(self,text="complete",failure=None):
        self.calls=0
        self.closed=0
        self.text=text
        self.failure=failure
        self.entered=asyncio.Event()
        self.release=None
        self.close_failure=None

    async def run(self,prompt):
        self.calls+=1
        self.entered.set()
        if self.release:
            await self.release.wait()
        if self.failure:
            raise self.failure
        return PeerReply("fixture-thread",f"turn-{self.calls}",self.text)

    async def close(self):
        self.closed+=1
        if self.close_failure:
            raise self.close_failure


def request(bridge,key="first",prompt="private-prompt",thread=None):
    return {"instance_id":bridge.status()["instance_id"],"key":key,
        "prompt":prompt,"expected_thread_id":thread}


def refused(result,code,*,uncertain=False,cleanup="not_attempted"):
    assert result["ok"] is False
    error=result["error"]
    assert error["code"]==code and error["uncertain"] is uncertain
    assert error["partial_usable"] is False and error["cleanup"]["status"]==cleanup
    assert error["cause"] and len(error["correlation_id"])==32
    assert "thread_id" in error and "turn_id" in error
    assert "private-prompt" not in json.dumps(result)


async def test_exact_delayed_retry_and_same_thread_continuation(config):
    peer=Conversation()
    bridge=Bridge(config,peer)
    assert bridge.status()["state"]=="ready" and bridge.status()["thread_id"] is None
    initial=request(bridge)
    first=await bridge.call(initial)
    assert first=={"ok":True,"thread_id":"fixture-thread","turn_id":"turn-1","text":"complete"}
    second=await bridge.call(request(bridge,"fix",thread="fixture-thread"))
    assert second["turn_id"]=="turn-2" and second["thread_id"]==first["thread_id"]
    assert await bridge.call(initial)==first
    assert peer.calls==2 and bridge.status()["thread_id"]=="fixture-thread"
    assert "peer_complete" not in first
    # Mutating a client receipt must not mutate the stored original.
    first["text"]="changed"
    assert (await bridge.call(initial))["text"]=="complete"


@pytest.mark.parametrize("change",[{"prompt":"different"},{"expected_thread_id":"fixture-thread"}])
async def test_every_changed_request_field_conflicts_before_new_turn(config,change):
    peer=Conversation(); bridge=Bridge(config,peer); initial=request(bridge)
    await bridge.call(initial)
    refused(await bridge.call({**initial,**change}),"CONFLICT")
    assert peer.calls==1 and bridge.status()["state"]=="ready"


async def test_restart_nonce_and_foreign_thread_refuse_before_backend_but_allow_fresh_intent(config):
    old=Bridge(config,Conversation()); initial=request(old)
    await old.call(initial)
    peer=Conversation(); new=Bridge(config,peer)
    refused(await new.call(initial),"ADAPTER_RESTARTED",uncertain=True)
    refused(await new.call(request(new,thread="fixture-thread")),"THREAD_MISMATCH")
    assert peer.calls==0 and new.status()["state"]=="ready"
    assert (await new.call(request(new,"explicit-fresh")))["ok"]


@pytest.mark.parametrize("patch",[{"key":True},{"key":""},{"key":"x"*65},
    {"prompt":4},{"prompt":""},{"prompt":"\ud800"},{"prompt":"x"*65537},
    {"expected_thread_id":False},{"model":"private-prompt"},{"instance_id":None}],
    ids=["boolean-key","empty-key","long-key","nontext","empty","surrogate","large","boolean-thread","extra","null-instance"])
async def test_strict_request_refusal_leaves_native_state_untouched(config,patch):
    peer=Conversation(); bridge=Bridge(config,peer)
    refused(await bridge.call({**request(bridge),**patch}),"INVALID_ARGUMENT")
    assert peer.calls==0 and peer.closed==0 and bridge.status()["state"]=="ready"


async def test_utf8_prompt_limit_and_missing_continuation(config):
    peer=Conversation(); bridge=Bridge(config,peer)
    assert (await bridge.call(request(bridge,prompt="😀"*16384)))["ok"]
    refused(await bridge.call(request(bridge,"next")),"THREAD_MISMATCH")
    refused(await bridge.call(request(bridge,"wide",prompt="😀"*16385,thread="fixture-thread")),"INVALID_ARGUMENT")
    assert peer.calls==1


async def test_concurrent_calls_refuse_busy_without_poisoning(config):
    peer=Conversation(); peer.release=asyncio.Event(); bridge=Bridge(config,peer)
    running=asyncio.create_task(bridge.call(request(bridge)))
    await peer.entered.wait()
    assert bridge.status()["state"]=="busy"
    refused(await bridge.call(request(bridge,"other")),"BUSY")
    peer.release.set()
    assert (await running)["ok"] and bridge.status()["state"]=="ready"
    assert peer.calls==1


async def test_twenty_keys_and_exact_retry_survive_limit(config):
    peer=Conversation(); bridge=Bridge(config,peer); initial=request(bridge)
    first=await bridge.call(initial)
    for index in range(1,20):
        assert (await bridge.call(request(bridge,str(index),thread="fixture-thread")))["ok"]
    refused(await bridge.call(request(bridge,"twenty-first",thread="fixture-thread")),"LIMIT_EXCEEDED")
    assert await bridge.call(initial)==first and peer.calls==20


async def test_cache_reservation_prevents_uncachable_turn_and_retains_only_prompt_digest(config,monkeypatch):
    from gauntlet_review.codex_bridge import engine
    monkeypatch.setattr(engine,"CACHE_BYTES",300000)
    peer=Conversation(text="x"*100000); bridge=Bridge(config,peer)
    initial=request(bridge,prompt="uniquely-private-prompt")
    first=await bridge.call(initial)
    refused(await bridge.call(request(bridge,"next",thread="fixture-thread")),"LIMIT_EXCEEDED")
    assert await bridge.call(initial)==first and peer.calls==1
    assert "uniquely-private-prompt" not in repr(bridge._cache)


@pytest.mark.parametrize("text,code",[("x"*131073,"LIMIT_EXCEEDED"),("\0"*30000,"LIMIT_EXCEEDED"),
    ("\ud800","INVALID_FINAL_MESSAGE"),("","INVALID_FINAL_MESSAGE")],
    ids=["text-cap","escaped-result-cap","surrogate","empty"])
async def test_invalid_or_oversized_complete_results_never_return_partial_text(config,text,code):
    peer=Conversation(text=text); bridge=Bridge(config,peer); initial=request(bridge)
    result=await bridge.call(initial)
    refused(result,code,uncertain=True,cleanup="succeeded")
    assert await bridge.call(initial)==result and peer.calls==1 and peer.closed==1
    refused(await bridge.call(request(bridge,"new")),"POISONED",uncertain=True)
    assert bridge.status()["state"]=="poisoned"


@pytest.mark.parametrize("close_failure,cleanup",[(None,"succeeded"),(OSError("private-prompt"),"failed")])
async def test_native_failure_is_safe_cached_and_poisoned(config,close_failure,cleanup):
    peer=Conversation(failure=OSError("private-prompt")); peer.close_failure=close_failure
    bridge=Bridge(config,peer); initial=request(bridge)
    result=await bridge.call(initial)
    refused(result,"SDK_FAILURE",uncertain=True,cleanup=cleanup)
    assert await bridge.call(initial)==result and peer.calls==1
    refused(await bridge.call(request(bridge,"new")),"POISONED",uncertain=True)


async def test_cancellation_propagates_after_cleanup_and_poisoning(config):
    peer=Conversation(); peer.release=asyncio.Event(); bridge=Bridge(config,peer)
    initial=request(bridge); running=asyncio.create_task(bridge.call(initial))
    await peer.entered.wait(); running.cancel()
    with pytest.raises(asyncio.CancelledError):
        await running
    assert peer.closed==1 and bridge.status()["state"]=="poisoned"
    refused(await bridge.call(initial),"CANCELLED",uncertain=True,cleanup="succeeded")
    assert peer.calls==1


async def test_deadline_includes_cleanup_and_refuses_unterminated_turn(config):
    peer=Conversation(); peer.release=asyncio.Event(); bridge=Bridge(config,peer)
    start=asyncio.get_running_loop().time()
    refused(await bridge.call(request(bridge)),"DEADLINE_EXCEEDED",uncertain=True,cleanup="succeeded")
    assert asyncio.get_running_loop().time()-start<10.5 and peer.closed==1


@pytest.mark.parametrize("timeout",[True,9,1801,"600"])
async def test_operator_timeout_is_strict_and_bounded(config,timeout):
    with pytest.raises(BridgeError) as error:
        Bridge(replace(config,timeout_seconds=timeout),Conversation())
    assert error.value.code=="CONFIGURATION_ERROR"


async def test_operator_cannot_use_author_role_or_relative_paths(config):
    from pathlib import Path
    for operator in (replace(config.operator,role="author"),replace(config.operator,repo_path=Path("relative"))):
        with pytest.raises(BridgeError) as error:
            Bridge(replace(config,operator=operator),Conversation())
        assert error.value.code=="CONFIGURATION_ERROR"
