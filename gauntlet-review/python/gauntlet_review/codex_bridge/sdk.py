"""Public Python SDK integration; no subprocess or JSON-RPC transport here."""
from __future__ import annotations

import asyncio
from dataclasses import asdict
import re
import sys

from openai_codex import AsyncCodex,ApprovalMode,CodexConfig,Sandbox
from openai_codex.errors import JsonRpcError,TransportClosedError
from openai_codex.generated.v2_all import (
    AgentMessageThreadItem,ItemCompletedNotification,MessagePhase,ModelReroutedNotification,
    ReasoningEffort,TurnCompletedNotification,TurnStatus,
)

from gauntlet_review.peer_model import MODEL_RE
from . import catalog
from .engine import (BridgeError,ModelCheckRefusal,PeerReply,TEXT_BYTES,_consume,_encode,_safe_id,mcp_result,
    reply_payload,validate_config)

EVENT_BYTES=64*1024*1024
_REASON=re.compile(r"[A-Za-z0-9_.-]{1,64}\Z")


def _sdk_error(original):
    """The adapter's typed failure for an SDK exception, or None for cancellation and process interrupts."""
    if isinstance(original,BridgeError):
        return original
    if isinstance(original,JsonRpcError):
        return BridgeError("SDK_FAILURE",cause="rpc")
    if isinstance(original,TransportClosedError):
        return BridgeError("SDK_FAILURE",cause="transport")
    if isinstance(original,Exception):
        return BridgeError("SDK_FAILURE",cause="sdk")
    return None


def _rerouted(payload):
    to=payload.to_model if type(payload.to_model) is str and MODEL_RE.fullmatch(payload.to_model) else None
    reason=getattr(payload.reason,"root",payload.reason)
    return to,reason if type(reason) is str and _REASON.fullmatch(reason) else None


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
        self._initialized=False

    async def _ensure_client(self):
        # Start and initialize explicitly: models() would otherwise initialize lazily, and an initialize error
        # means a broken client, never a catalog answer.
        if self.client is None:
            self.client=AsyncCodex(CodexConfig(cwd=str(self.config.operator.repo_path)))
        if not self._initialized:
            await self.client.__aenter__()
            self._initialized=True

    async def check(self,selection):
        """Refuses (ModelCheckRefusal) a selection the catalog does not list; starts no turn."""
        try:
            await self._ensure_client()
            try:
                response=await self.client.models(include_hidden=True)
            except JsonRpcError as error:
                raise ModelCheckRefusal("CATALOG_UNAVAILABLE",cause="model_check") from error
            code=catalog.check(catalog.from_response(response),selection.model,selection.effort)
        except BaseException as original:
            error=_sdk_error(original)
            if error is None:
                raise
            if error is original:
                raise
            raise error from original
        if code is not None:
            raise ModelCheckRefusal(code,cause="model_check")

    async def run(self,prompt,selection):
        stream=None
        primary=None
        rerouted=None
        try:
            await self._ensure_client()
            if self.thread is None:
                self.thread=await self.client.thread_start(cwd=str(self.config.operator.repo_path),
                    config=reviewer_config(self.config),model=selection.model,
                    approval_mode=ApprovalMode.deny_all,sandbox=Sandbox.read_only)
                self.thread_id=self.thread.id
            self.active=await self.thread.turn(prompt,model=selection.model,effort=ReasoningEffort(selection.effort))
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
                if (event.method=="model/rerouted" and isinstance(payload,ModelReroutedNotification)
                        and payload.thread_id==self.thread_id and payload.turn_id==self.turn_id):
                    rerouted=_rerouted(payload)
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
                    reply=PeerReply(self.thread_id,self.turn_id,final,rerouted)
                    mcp_result(reply_payload(reply,selection))
                    return reply
            raise BridgeError("MISSING_TERMINAL",cause="unterminated_stream")
        except BaseException as original:
            if isinstance(original,UnicodeError):
                error=BridgeError("INVALID_FINAL_MESSAGE",cause="invalid_final")
            else:
                error=_sdk_error(original)
            if error is None:
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
