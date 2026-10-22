"""Real typed SDK messages; replace only the native/model boundary."""
import asyncio
from dataclasses import asdict,replace
import json
import sys

import pytest

pytest.importorskip("openai_codex")
from openai_codex import ApprovalMode,Sandbox
from openai_codex.errors import JsonRpcError,TransportClosedError
from openai_codex.generated.v2_all import ItemCompletedNotification,TurnCompletedNotification
from openai_codex.models import Notification,UnknownNotification

from gauntlet_review.codex_bridge.engine import Bridge,BridgeError
from gauntlet_review.codex_bridge import sdk

pytestmark=pytest.mark.anyio


def message(thread="thread-1",turn="turn-1",text="complete",phase="final_answer",method="item/completed"):
    return Notification(method,ItemCompletedNotification.model_validate({"threadId":thread,
        "turnId":turn,"completedAtMs":1,"item":{"id":"item-1","type":"agentMessage","text":text,"phase":phase}}))


def terminal(thread="thread-1",turn="turn-1",status="completed"):
    return Notification("turn/completed",TurnCompletedNotification.model_validate({"threadId":thread,
        "turn":{"id":turn,"items":[],"itemsView":"full","status":status}}))


class Handle:
    def __init__(self,events,number=1):
        self.id=f"turn-{number}"; self.thread_id="thread-1"
        self.events=events; self.consumed=0; self.interrupted=False; self.closed=False

    async def stream(self):
        try:
            for event in self.events:
                self.consumed+=1
                if isinstance(event,BaseException):
                    raise event
                yield event
        finally:
            self.closed=True

    async def interrupt(self):
        self.interrupted=True


class Native:
    def __init__(self,events):
        self.events=events; self.config=None; self.options=None; self.starts=0
        self.handles=[]; self.closed=False; self.failure=None; self.close_failure=None
        self.id="thread-1"

    def create(self,config):
        self.config=config
        return self

    async def thread_start(self,**options):
        self.starts+=1; self.options=options
        if self.failure:
            raise self.failure
        return self

    async def turn(self,prompt):
        number=len(self.handles)+1
        events=self.events(number) if callable(self.events) else self.events
        handle=Handle(events,number); self.handles.append(handle)
        return handle

    async def close(self):
        self.closed=True
        if self.close_failure:
            raise self.close_failure


def conversation(config,monkeypatch,events):
    native=Native(events)
    monkeypatch.setattr(sdk,"AsyncCodex",native.create)
    return sdk.SdkConversation(config),native


async def test_public_sdk_start_configuration_and_same_thread_are_locked(config,monkeypatch):
    peer,native=conversation(config,monkeypatch,lambda n:[message(turn=f"turn-{n}"),terminal(turn=f"turn-{n}")])
    assert native.config is None
    first=await peer.run("review")
    second=await peer.run("fix")
    assert (first.thread_id,first.turn_id,second.thread_id,second.turn_id)==("thread-1","turn-1","thread-1","turn-2")
    assert native.starts==1
    options=native.options
    assert options["approval_mode"] is ApprovalMode.deny_all and options["sandbox"] is Sandbox.read_only
    assert options["model"] is None and options["cwd"]==str(config.operator.repo_path)
    required=options["config"]["mcp_servers"]["gauntlet-reviewer"]
    assert required["required"] is True and required["command"]==sys.executable
    assert required["enabled_tools"]==["read_review","record_evidence","review_status","submit_review"]
    assert required["enabled"] is True and required["disabled_tools"]==[]
    assert required["default_tools_approval_mode"]=="prompt"
    assert required["tools"]=={name:{"approval_mode":"approve","output_token_limit":262144} for name in required["enabled_tools"]}
    assert required["args"]==["-m","gauntlet_review.collaborative","--repo",str(config.operator.repo_path),
        "--state-dir",str(config.operator.state_dir),"--repository-id","fixture","--source-ref","refs/heads/topic",
        "--target-ref","refs/heads/main","--participant","peer","--role","reviewer"]
    assert native.config.codex_bin is None and native.config.launch_args_override is None
    assert native.config.env is None
    await peer.close()
    assert native.closed and all(handle.closed for handle in native.handles)


@pytest.mark.parametrize("events,code",[
    ([message()],"MISSING_TERMINAL"),
    ([message(),terminal(thread="foreign")],"MISSING_TERMINAL"),
    ([message(),terminal(turn="foreign")],"MISSING_TERMINAL"),
    ([message(thread="foreign"),terminal()],"INVALID_FINAL_MESSAGE"),
    ([message(turn="foreign"),terminal()],"INVALID_FINAL_MESSAGE"),
    ([message(phase="partial_answer"),terminal()],"INVALID_FINAL_MESSAGE"),
    ([message(phase="commentary"),terminal()],"INVALID_FINAL_MESSAGE"),
    ([message(method="item/started"),terminal()],"INVALID_FINAL_MESSAGE"),
    ([terminal()],"INVALID_FINAL_MESSAGE"),
    ([message(),terminal(status="failed")],"TURN_FAILED"),
    ([message(),terminal(status="interrupted")],"TURN_FAILED"),
],ids=["eof","wrong-terminal-thread","wrong-terminal-turn","wrong-final-thread","wrong-final-turn",
       "partial","commentary","started","absent-final","failed","interrupted"])
async def test_only_matching_successful_terminal_and_complete_final_message_can_succeed(config,monkeypatch,events,code):
    peer,native=conversation(config,monkeypatch,events)
    bridge=Bridge(config,peer)
    result=await bridge.call({"instance_id":bridge.instance_id,"key":"first","prompt":"review","expected_thread_id":None})
    assert not result["ok"] and result["error"]["code"]==code
    assert result["error"]["uncertain"] and not result["error"]["partial_usable"]
    assert bridge.status()["state"]=="poisoned" and native.closed
    assert bridge.status()["thread_id"]=="thread-1"
    assert native.handles[0].closed


def event_bytes(event):
    payload=event.payload.model_dump(mode="json",by_alias=True) if hasattr(event.payload,"model_dump") else asdict(event.payload)
    return len(json.dumps({"method":event.method,"payload":payload},ensure_ascii=False,separators=(",",":")).encode("utf-8"))


@pytest.mark.parametrize("overflow",[False,True])
async def test_exact_decoded_event_limit_and_immediate_overflow_stop(config,monkeypatch,overflow):
    final=message(); end=terminal()
    empty=Notification("unknown",UnknownNotification({"body":""}))
    size=8*1024*1024-event_bytes(empty)-event_bytes(final)-event_bytes(end)+int(overflow)
    full=Notification("unknown",UnknownNotification({"body":"x"*size}))
    peer,native=conversation(config,monkeypatch,[full,final,end,AssertionError("consumed after terminal/overflow")])
    if overflow:
        with pytest.raises(BridgeError) as error:
            await peer.run("review")
        assert error.value.code=="LIMIT_EXCEEDED"
    else:
        assert (await peer.run("review")).text=="complete"
    await peer.close()
    assert native.handles[0].consumed==3 and native.handles[0].closed


async def test_one_oversized_decoded_event_stops_before_following_message(config,monkeypatch):
    huge=Notification("unknown",UnknownNotification({"body":"x"*(8*1024*1024)}))
    peer,native=conversation(config,monkeypatch,[huge,AssertionError("read past overflow")])
    with pytest.raises(BridgeError) as error:
        await peer.run("review")
    assert error.value.code=="LIMIT_EXCEEDED" and native.handles[0].consumed==1
    await peer.close()
    assert native.handles[0].interrupted


@pytest.mark.parametrize("failure,cause",[(JsonRpcError(-1,"private-sdk-detail"),"rpc"),
    (TransportClosedError("private-sdk-detail"),"transport")],ids=["rpc","transport"])
async def test_sdk_typed_causes_are_chained_without_leaking_native_messages(config,monkeypatch,failure,cause):
    peer,native=conversation(config,monkeypatch,[]); native.failure=failure
    with pytest.raises(BridgeError) as error:
        await peer.run("review")
    assert error.value.__cause__ is failure and error.value.cause==cause
    bridge=Bridge(config,peer)
    result=await bridge.call({"instance_id":bridge.instance_id,"key":"first","prompt":"review","expected_thread_id":None})
    assert result["error"]["cause"]==cause and "private-sdk-detail" not in json.dumps(result)
    assert native.closed


async def test_interrupt_and_close_failures_both_retain_typed_causes(config,monkeypatch):
    peer,native=conversation(config,monkeypatch,[message()])
    with pytest.raises(BridgeError):
        await peer.run("review")
    interrupt_error=JsonRpcError(-1,"private-interrupt")
    close_error=TransportClosedError("private-close")
    async def failed_interrupt():
        raise interrupt_error
    native.handles[0].interrupt=failed_interrupt
    native.close_failure=close_error
    with pytest.raises(BridgeError) as caught:
        await peer.close()
    assert native.closed
    combined=caught.value.__cause__
    assert isinstance(combined,ExceptionGroup)
    assert [item.cause for item in combined.exceptions]==["interrupt_failure","close_failure"]
    assert [item.__cause__ for item in combined.exceptions]==[interrupt_error,close_error]


async def test_cancelled_interrupt_task_still_attempts_sdk_close(config,monkeypatch):
    peer,native=conversation(config,monkeypatch,[])
    with pytest.raises(BridgeError):
        await peer.run("review")
    cancelled=asyncio.CancelledError("private-interrupt")
    async def cancelled_interrupt():
        raise cancelled
    native.handles[0].interrupt=cancelled_interrupt
    with pytest.raises(BridgeError) as caught:
        await peer.close()
    assert native.closed
    assert caught.value.code=="CLEANUP_FAILURE" and caught.value.cause=="interrupt_failure"
    assert caught.value.__cause__ is cancelled
