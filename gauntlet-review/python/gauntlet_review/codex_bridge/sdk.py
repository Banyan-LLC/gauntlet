"""Public Python SDK integration; no subprocess or JSON-RPC transport here."""
from __future__ import annotations

import asyncio
from dataclasses import asdict
import sys

from openai_codex import AsyncCodex,ApprovalMode,CodexConfig,Sandbox
from openai_codex.errors import JsonRpcError,TransportClosedError
from openai_codex.generated.v2_all import (
    AgentMessageThreadItem,ItemCompletedNotification,MessagePhase,
    TurnCompletedNotification,TurnStatus,
)

from .engine import BridgeError,PeerReply,TEXT_BYTES,_consume,_encode,_safe_id,mcp_result,validate_config

EVENT_BYTES=8*1024*1024


def reviewer_config(config):
    operator=config.operator
    tools=["read_review","record_evidence","review_status","submit_review"]
    return {"mcp_servers":{"gauntlet-reviewer":{"command":sys.executable,"args":[
        "-m","gauntlet_review.collaborative","--repo",str(operator.repo_path),
        "--state-dir",str(operator.state_dir),"--repository-id",operator.repository_id,
        "--source-ref",operator.source_ref.decode("utf-8"),"--target-ref",operator.target_ref.decode("utf-8"),
        "--participant",operator.participant,"--role","reviewer"],"required":True,
        "enabled":True,"enabled_tools":tools,"disabled_tools":[],"default_tools_approval_mode":"prompt",
        # These exact core operations are operator-authorized. This does not
        # enable shell escalation or approve any other MCP tool. A byte-sized
        # token allowance raises the native output budget. Hosts may apply
        # additional formatting limits; clients must verify complete receipts
        # and choose smaller pages when needed.
        "tools":{name:{"approval_mode":"approve","output_token_limit":256*1024} for name in tools}}}}


class SdkConversation:
    def __init__(self,config):
        self.config=validate_config(config)
        self.client=None
        self.thread=None
        self.active=None
        self.thread_id=None
        self.turn_id=None
        self._stream_close_failure=None

    async def run(self,prompt):
        stream=None
        primary=None
        try:
            if self.client is None:
                self.client=AsyncCodex(CodexConfig(cwd=str(self.config.operator.repo_path)))
            if self.thread is None:
                self.thread=await self.client.thread_start(cwd=str(self.config.operator.repo_path),
                    config=reviewer_config(self.config),model=self.config.model,
                    approval_mode=ApprovalMode.deny_all,sandbox=Sandbox.read_only)
                self.thread_id=self.thread.id
            self.active=await self.thread.turn(prompt)
            self.turn_id=self.active.id
            if self.active.thread_id!=self.thread_id:
                raise BridgeError("INVALID_TERMINAL",cause="thread_mismatch")
            final=None
            explicit_final=False
            decoded=0
            stream=self.active.stream()
            async for event in stream:
                payload=event.payload
                data=payload.model_dump(mode="json",by_alias=True) if hasattr(payload,"model_dump") else asdict(payload)
                decoded+=len(_encode({"method":event.method,"payload":data}))
                if decoded>EVENT_BYTES:
                    raise BridgeError("LIMIT_EXCEEDED",cause="event_limit")
                if (event.method=="item/completed" and isinstance(payload,ItemCompletedNotification)
                        and payload.thread_id==self.thread_id and payload.turn_id==self.turn_id):
                    item=payload.item.root
                    if isinstance(item,AgentMessageThreadItem) and (
                            item.phase is MessagePhase.final_answer or item.phase is None and not explicit_final):
                        if type(item.text) is not str or not item.text:
                            raise BridgeError("INVALID_FINAL_MESSAGE",cause="invalid_final")
                        if len(item.text.encode("utf-8","strict"))>TEXT_BYTES:
                            raise BridgeError("LIMIT_EXCEEDED",cause="text_limit")
                        final=item.text
                        explicit_final=item.phase is MessagePhase.final_answer
                if (event.method=="turn/completed" and isinstance(payload,TurnCompletedNotification)
                        and payload.thread_id==self.thread_id and payload.turn.id==self.turn_id):
                    if payload.turn.status is not TurnStatus.completed or payload.turn.error is not None:
                        raise BridgeError("TURN_FAILED",cause="terminal_failure")
                    if final is None:
                        raise BridgeError("INVALID_FINAL_MESSAGE",cause="missing_final")
                    # These shared validators include the complete serialized
                    # result, whose escaped duplicate copies can exceed text size.
                    if not _safe_id(self.thread_id) or not _safe_id(self.turn_id):
                        raise BridgeError("INVALID_FINAL_MESSAGE",cause="invalid_identity")
                    mcp_result({"ok":True,"thread_id":self.thread_id,
                        "turn_id":self.turn_id,"text":final})
                    return PeerReply(self.thread_id,self.turn_id,final)
            raise BridgeError("MISSING_TERMINAL",cause="unterminated_stream")
        except BaseException as original:
            if isinstance(original,BridgeError):
                error=original
            elif isinstance(original,JsonRpcError):
                error=BridgeError("SDK_FAILURE",cause="rpc")
            elif isinstance(original,TransportClosedError):
                error=BridgeError("SDK_FAILURE",cause="transport")
            elif isinstance(original,UnicodeError):
                error=BridgeError("INVALID_FINAL_MESSAGE",cause="invalid_final")
            elif isinstance(original,Exception):
                error=BridgeError("SDK_FAILURE",cause="sdk")
            else:
                # Cancellation and process interrupts remain primary even if
                # closing the stream also fails.
                primary=original
                raise
            primary=error
            error.thread_id=self.thread_id
            error.turn_id=self.turn_id
            if error is original:
                raise
            raise error from original
        finally:
            if stream is not None:
                try:
                    await stream.aclose()
                except (Exception,asyncio.CancelledError) as cleanup:
                    failure=BridgeError("CLEANUP_FAILURE",cause="stream_close_failure",
                        thread_id=self.thread_id,turn_id=self.turn_id)
                    failure.__cause__=cleanup
                    self._stream_close_failure=failure
                    if primary is not None:
                        if primary.__cause__ is not None:
                            raise primary from BaseExceptionGroup("SDK turn and stream cleanup failures",
                                [primary.__cause__,cleanup])
                        raise primary from cleanup
                    if isinstance(cleanup,asyncio.CancelledError):
                        raise
                    raise failure from cleanup
                else:
                    # Retain uncertain turns for close() to interrupt. A terminal
                    # receipt alone does not certify validation or stream cleanup.
                    if primary is None:
                        self.active=None

    async def close(self):
        # Interruption has its own short share of the caller's remaining budget;
        # a failed interrupt cannot prevent attempting SDK close. SDK-owned
        # workers may outlive these waits; no process-retirement claim is made.
        failures=[] if self._stream_close_failure is None else [self._stream_close_failure]
        if self.active is not None:
            task=asyncio.create_task(self.active.interrupt())
            done,_=await asyncio.wait({task},timeout=1)
            if not done:
                task.cancel(); task.add_done_callback(_consume)
                failures.append(BridgeError("CLEANUP_FAILURE",cause="interrupt_deadline"))
            else:
                try:
                    task.result()
                except (Exception,asyncio.CancelledError) as error:
                    failure=BridgeError("CLEANUP_FAILURE",cause="interrupt_failure")
                    failure.__cause__=error
                    failures.append(failure)
        try:
            if self.client is not None:
                await self.client.close()
        except (Exception,asyncio.CancelledError) as error:
            failure=BridgeError("CLEANUP_FAILURE",cause="close_failure")
            failure.__cause__=error
            failures.append(failure)
        if len(failures)==1:
            raise failures[0]
        if failures:
            raise BridgeError("CLEANUP_FAILURE",cause=failures[-1].cause) from ExceptionGroup(
                "SDK cleanup failures",failures)
