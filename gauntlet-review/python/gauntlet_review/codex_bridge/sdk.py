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

from .engine import BridgeError,PeerReply,TEXT_BYTES,_consume,_encode,validate_config

EVENT_BYTES=8*1024*1024


def reviewer_config(config):
    operator=config.operator
    return {"mcp_servers":{"gauntlet-reviewer":{"command":sys.executable,"args":[
        "-m","gauntlet_review.collaborative","--repo",str(operator.repo_path),
        "--state-dir",str(operator.state_dir),"--repository-id",operator.repository_id,
        "--source-ref",operator.source_ref.decode("utf-8"),"--target-ref",operator.target_ref.decode("utf-8"),
        "--participant",operator.participant,"--role","reviewer"],"required":True}}}


class SdkConversation:
    def __init__(self,config):
        self.config=validate_config(config)
        self.client=None
        self.thread=None
        self.active=None
        self.thread_id=None
        self.turn_id=None

    async def run(self,prompt):
        stream=None
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
                    self.active=None
                    if payload.turn.status is not TurnStatus.completed or payload.turn.error is not None:
                        raise BridgeError("TURN_FAILED",cause="terminal_failure")
                    if final is None:
                        raise BridgeError("INVALID_FINAL_MESSAGE",cause="missing_final")
                    return PeerReply(self.thread_id,self.turn_id,final)
            raise BridgeError("MISSING_TERMINAL",cause="unterminated_stream")
        except BridgeError as error:
            error.thread_id=self.thread_id
            error.turn_id=self.turn_id
            raise
        except JsonRpcError as error:
            raise BridgeError("SDK_FAILURE",cause="rpc",thread_id=self.thread_id,turn_id=self.turn_id) from error
        except TransportClosedError as error:
            raise BridgeError("SDK_FAILURE",cause="transport",thread_id=self.thread_id,turn_id=self.turn_id) from error
        except UnicodeError as error:
            raise BridgeError("INVALID_FINAL_MESSAGE",cause="invalid_final",thread_id=self.thread_id,turn_id=self.turn_id) from error
        except Exception as error:
            raise BridgeError("SDK_FAILURE",cause="sdk",thread_id=self.thread_id,turn_id=self.turn_id) from error
        finally:
            if stream is not None:
                await stream.aclose()

    async def close(self):
        # Interruption has its own short share of the caller's remaining budget;
        # a failed interrupt cannot prevent attempting SDK close. SDK-owned
        # workers may outlive these waits; no process-retirement claim is made.
        failure=None
        if self.active is not None:
            task=asyncio.create_task(self.active.interrupt())
            done,_=await asyncio.wait({task},timeout=1)
            if not done:
                task.cancel(); task.add_done_callback(_consume)
                failure=BridgeError("CLEANUP_FAILURE",cause="interrupt_deadline")
            else:
                try:
                    task.result()
                except Exception as error:
                    failure=BridgeError("CLEANUP_FAILURE",cause="interrupt_failure")
                    failure.__cause__=error
        try:
            if self.client is not None:
                await self.client.close()
        except Exception as error:
            raise BridgeError("CLEANUP_FAILURE",cause="close_failure") from error
        if failure is not None:
            raise failure
