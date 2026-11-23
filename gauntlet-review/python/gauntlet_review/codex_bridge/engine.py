"""One process-local conversation with bounded admission and exact receipts.

Limits cover logical application data and waits, not SDK buffers or native
process retirement. The official SDK owns those native resources.
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import uuid
from typing import Protocol

import anyio
from pydantic import BaseModel,ConfigDict,ValidationError,field_validator

from gauntlet_review import peer_model
from gauntlet_review.collaborative.contracts import CoreError,OperatorConfig,validate_operator_config

PROMPT_BYTES=64*1024
TEXT_BYTES=128*1024
RESULT_BYTES=256*1024
CACHE_BYTES=4*1024*1024
MAX_KEYS=20
CLEANUP_SECONDS=5
# A turn deadline normally stays within 10..1800 seconds. An operator can
# deliberately raise only the ceiling, to 7200, with the explicit override flag.
TIMEOUT_MIN=10
TIMEOUT_MAX=1800
EXTENDED_TIMEOUT_MAX=7200
EXTENDED_TIMEOUT_FLAG="--allow-extended-timeout"
_IDENTIFIER=re.compile(r"[A-Za-z0-9_.:-]{1,128}\Z")


class BridgeError(Exception):
    def __init__(self,code,*,cause="validation",thread_id=None,turn_id=None):
        self.code,self.cause=code,cause
        self.thread_id,self.turn_id=thread_id,turn_id
        super().__init__(code)


class ModelCheckRefusal(BridgeError):
    """A certain refusal from the catalog check before a turn: MODEL_UNAVAILABLE, EFFORT_NOT_SUPPORTED or
    CATALOG_UNAVAILABLE. Only Conversation.check raises it; the bridge treats it as certain only from there."""


@dataclass(frozen=True)
class BridgeConfig:
    operator: OperatorConfig
    model: str|None=None
    timeout_seconds: int=600
    extended_timeout: bool=False
    # Bytes of RESULT_BYTES kept free for what a host adds to every reply (a session server's binding).
    # Zero for the explicit-tuple adapter, whose limits are unchanged.
    result_reserve: int=0
    # Appended so positional construction stays valid. Fixed mode uses model/effort (or the built-in default);
    # settings mode reads the operator's peer-model.json under this root for every turn and status.
    effort: str|None=None
    model_settings_root: Path|None=None


@dataclass(frozen=True)
class PeerReply:
    thread_id: str
    turn_id: str
    text: str
    rerouted: tuple[str|None,str|None]|None=None


class Conversation(Protocol):
    async def check(self,selection: peer_model.Selection)->None: ...
    async def run(self,prompt: str,selection: peer_model.Selection)->PeerReply: ...
    async def close(self)->None: ...


def reply_payload(reply,selection):
    """A completed turn's reply, naming the model and effort that turn used."""
    model=selection.public()
    if reply.rerouted is not None:
        model["rerouted"]={"to":reply.rerouted[0],"reason":reply.rerouted[1]}
    return {"ok":True,"thread_id":reply.thread_id,"turn_id":reply.turn_id,"text":reply.text,"peer_model":model}


def timeout_ceiling(extended):
    return EXTENDED_TIMEOUT_MAX if extended else TIMEOUT_MAX


def timeout_refusal(seconds,extended):
    """None for an accepted turn deadline, else the fixed structured refusal. It names the accepted range and,
    for a value only the override would accept, the opt-in flag. It never echoes the refused value."""
    ceiling=timeout_ceiling(extended)
    if TIMEOUT_MIN<=seconds<=ceiling:
        return None
    body={"code":"TIMEOUT_OUT_OF_RANGE","accepted":{"min":TIMEOUT_MIN,"max":ceiling}}
    if not extended and TIMEOUT_MAX<seconds<=EXTENDED_TIMEOUT_MAX:
        body["opt_in"]={"flag":EXTENDED_TIMEOUT_FLAG,"max":EXTENDED_TIMEOUT_MAX}
    return body


def validate_config(config):
    try:
        if not isinstance(config,BridgeConfig):
            raise BridgeError("CONFIGURATION_ERROR")
        validate_operator_config(config.operator)
        if config.operator.role!="reviewer":
            raise BridgeError("CONFIGURATION_ERROR")
        if type(config.extended_timeout) is not bool or type(config.timeout_seconds) is not int:
            raise BridgeError("CONFIGURATION_ERROR")
        if type(config.result_reserve) is not int or not 0<=config.result_reserve<=RESULT_BYTES//4:
            raise BridgeError("CONFIGURATION_ERROR")
        if timeout_refusal(config.timeout_seconds,config.extended_timeout) is not None:
            raise BridgeError("CONFIGURATION_ERROR",cause="timeout_range")
        if config.model is not None and (type(config.model) is not str or
                not peer_model.MODEL_RE.fullmatch(config.model)):
            raise BridgeError("CONFIGURATION_ERROR")
        if config.effort is not None and (type(config.effort) is not str or
                not peer_model.EFFORT_RE.fullmatch(config.effort)):
            raise BridgeError("CONFIGURATION_ERROR")
        if config.model_settings_root is not None:
            if not isinstance(config.model_settings_root,Path) or not config.model_settings_root.is_absolute():
                raise BridgeError("CONFIGURATION_ERROR",cause="model_mode")
            if config.model is not None or config.effort is not None:
                raise BridgeError("CONFIGURATION_ERROR",cause="model_mode")
    except CoreError as error:
        raise BridgeError("CONFIGURATION_ERROR") from error
    return config


class ReviewRequest(BaseModel):
    model_config=ConfigDict(strict=True,extra="forbid")
    instance_id: str
    key: str
    prompt: str
    expected_thread_id: str|None

    @field_validator("instance_id")
    @classmethod
    def instance(cls,value):
        if not re.fullmatch(r"[0-9a-f]{32}",value):
            raise ValueError("instance")
        return value

    @field_validator("key")
    @classmethod
    def key_value(cls,value):
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}",value):
            raise ValueError("key")
        return value

    @field_validator("prompt")
    @classmethod
    def prompt_value(cls,value):
        if not 0<len(value.encode("utf-8","strict"))<=PROMPT_BYTES:
            raise ValueError("prompt bytes")
        return value

    @field_validator("expected_thread_id")
    @classmethod
    def thread_value(cls,value):
        if value is not None and not _IDENTIFIER.fullmatch(value):
            raise ValueError("thread")
        return value


def _encode(value):
    return json.dumps(value,ensure_ascii=False,allow_nan=False,separators=(",",":")).encode("utf-8","strict")


def mcp_result(payload,reserve=0):
    """Build the actual SDK result; measure both text and structured copies against RESULT_BYTES less reserve."""
    from mcp_types import CallToolResult
    result=CallToolResult(content=[{"type":"text","text":_encode(payload).decode("utf-8")}],
        structured_content=payload,is_error=not payload["ok"])
    if len(result.model_dump_json(by_alias=True,exclude_none=True).encode("utf-8"))>RESULT_BYTES-reserve:
        raise BridgeError("LIMIT_EXCEEDED",cause="result_limit")
    return result


def _consume(task):
    # Detached SDK worker completion is observed without an unbounded await.
    if not task.cancelled():
        task.exception()


def _safe_id(value):
    return value if type(value) is str and _IDENTIFIER.fullmatch(value) else None


class Bridge:
    def __init__(self,config:BridgeConfig,conversation:Conversation):
        self.config=validate_config(config)
        self.conversation=conversation
        self.instance_id=uuid.uuid4().hex
        self.thread_id=None
        self._busy=False
        self._poisoned=False
        self._closed=False
        self._cache={}

    def selection(self):
        if self.config.model_settings_root is None:
            return peer_model.fixed(self.config.model,self.config.effort)
        try:
            return peer_model.selection_for(self.config.model_settings_root,self.config.operator.repository_id)
        except peer_model.SettingsError as error:
            raise BridgeError("MODEL_SETTINGS_INVALID",cause="model_settings") from error

    def status(self):
        payload={"ok":True,"instance_id":self.instance_id,"thread_id":self._owned_thread(),
            "state":"poisoned" if self._poisoned else "busy" if self._busy else "ready"}
        try:
            payload["peer_model"]=self.selection().public()
        except BridgeError as error:
            payload["peer_model"]={"error":error.code}
        # Shown only when the operator opted in, so the default status is unchanged.
        if self.config.extended_timeout:
            payload["extended_timeout"]={"timeout_seconds":self.config.timeout_seconds,
                "max_seconds":EXTENDED_TIMEOUT_MAX}
        return payload

    def _owned_thread(self):
        return self.thread_id or _safe_id(getattr(self.conversation,"thread_id",None))

    def error_response(self,error,*,uncertain=False,cleanup=None):
        payload={"ok":False,"error":{"code":error.code,"cause":error.cause,
            "correlation_id":uuid.uuid4().hex,"uncertain":uncertain,"partial_usable":False,
            "thread_id":_safe_id(error.thread_id) or self._owned_thread(),
            "turn_id":_safe_id(error.turn_id) or _safe_id(getattr(self.conversation,"turn_id",None)),
            "cleanup":cleanup or {"status":"not_attempted","cause":None}}}
        mcp_result(payload,self.config.result_reserve)
        return payload

    async def _cleanup(self,deadline):
        if self._closed:
            return {"status":"not_attempted","cause":None}
        self._closed=True
        with anyio.CancelScope(shield=True):
            task=asyncio.create_task(self.conversation.close())
            done,_=await asyncio.wait({task},timeout=max(0,deadline-asyncio.get_running_loop().time()))
            if not done:
                task.cancel(); task.add_done_callback(_consume)
                return {"status":"timed_out","cause":"cleanup_deadline"}
            try:
                task.result()
            except BaseException as error:
                if isinstance(error,(KeyboardInterrupt,SystemExit)):
                    raise
                return {"status":"failed","cause":"cleanup_failure"}
        return {"status":"succeeded","cause":None}

    async def close(self):
        self._poisoned=True
        return await self._cleanup(asyncio.get_running_loop().time()+CLEANUP_SECONDS)

    async def call(self,request:dict)->dict:
        try:
            parsed=ReviewRequest.model_validate(request,strict=True)
        except (ValidationError,UnicodeError) as error:
            failure=BridgeError("INVALID_ARGUMENT")
            failure.__cause__=error
            return self.error_response(failure)
        if parsed.instance_id!=self.instance_id:
            return self.error_response(BridgeError("ADAPTER_RESTARTED",cause="instance_mismatch"),uncertain=True)
        digest=hashlib.sha256(_encode({"instance_id":parsed.instance_id,"key":parsed.key,
            "prompt_sha256":hashlib.sha256(parsed.prompt.encode("utf-8")).hexdigest(),
            "expected_thread_id":parsed.expected_thread_id})).hexdigest()
        if parsed.key in self._cache:
            record=json.loads(self._cache[parsed.key])
            if digest!=record["request_digest"]:
                return self.error_response(BridgeError("CONFLICT",cause="key_conflict"))
            payload=record["response"]
            mcp_result(payload,self.config.result_reserve)
            return payload
        if self._busy:
            return self.error_response(BridgeError("BUSY",cause="concurrent_call"))
        if self._poisoned:
            return self.error_response(BridgeError("POISONED",cause="uncertain_conversation"),uncertain=True)
        if parsed.expected_thread_id!=self.thread_id:
            return self.error_response(BridgeError("THREAD_MISMATCH",cause="thread_mismatch"))
        # A complete result plus fixed bounded record fields must fit before work.
        reservation=RESULT_BYTES+2048
        if len(self._cache)>=MAX_KEYS or sum(map(len,self._cache.values()))+reservation>CACHE_BYTES:
            return self.error_response(BridgeError("LIMIT_EXCEEDED",cause="cache_limit"))
        try:
            # Fresh for every turn, so an operator's switch reaches the next turn of an open conversation.
            selection=self.selection()
        except BridgeError as error:
            return self.error_response(error)
        self._busy=True
        deadline=asyncio.get_running_loop().time()+self.config.timeout_seconds

        async def attempt():
            try:
                await self.conversation.check(selection)
            except ModelCheckRefusal as refusal:
                # Returned, not raised: only a refusal from the check itself is certain (no turn started).
                return refusal
            return await self.conversation.run(parsed.prompt,selection)

        task=asyncio.create_task(attempt())
        cancelled=None
        try:
            done,_=await asyncio.wait({task},timeout=max(0,deadline-CLEANUP_SECONDS-asyncio.get_running_loop().time()))
            if not done:
                raise BridgeError("DEADLINE_EXCEEDED",cause="deadline")
            try:
                reply=task.result()
            except asyncio.CancelledError as error:
                # This is cancellation of the SDK task, not cancellation of
                # the caller waiting above. Return an uncertain receipt.
                raise BridgeError("SDK_FAILURE",cause="cancellation") from error
            if isinstance(reply,ModelCheckRefusal):
                # Certain: nothing ran, nothing to clean up, nothing cached, the conversation stays usable.
                return self.error_response(reply)
            if (not isinstance(reply,PeerReply) or not _safe_id(reply.thread_id) or not _safe_id(reply.turn_id)
                    or self.thread_id is not None and self.thread_id!=reply.thread_id):
                raise BridgeError("INVALID_FINAL_MESSAGE",cause="invalid_identity")
            self.thread_id=reply.thread_id
            try:
                if type(reply.text) is not str or not reply.text:
                    raise BridgeError("INVALID_FINAL_MESSAGE",cause="invalid_final")
                size=len(reply.text.encode("utf-8","strict"))
            except UnicodeError as error:
                raise BridgeError("INVALID_FINAL_MESSAGE",cause="invalid_final") from error
            if size>TEXT_BYTES:
                raise BridgeError("LIMIT_EXCEEDED",cause="text_limit",turn_id=reply.turn_id)
            payload=reply_payload(reply,selection)
            mcp_result(payload,self.config.result_reserve)
        except (Exception,asyncio.CancelledError) as original:
            if isinstance(original,asyncio.CancelledError):
                cancelled=original
                failure=BridgeError("CANCELLED",cause="cancellation")
                failure.__cause__=original
            elif isinstance(original,BridgeError):
                failure=original
            else:
                failure=BridgeError("SDK_FAILURE",cause="sdk")
                failure.__cause__=original
            self._poisoned=True
            if not task.done():
                task.cancel(); task.add_done_callback(_consume)
            cleanup=await self._cleanup(deadline)
            failure.thread_id=failure.thread_id or getattr(self.conversation,"thread_id",None)
            failure.turn_id=failure.turn_id or getattr(self.conversation,"turn_id",None)
            payload=self.error_response(failure,uncertain=True,cleanup=cleanup)
        finally:
            self._busy=False
        record=_encode({"key":parsed.key,"request_digest":digest,"response":payload})
        # Reservation is conservative for every bounded result; never evict history.
        if len(record)>reservation:
            raise BridgeError("INTERNAL_ERROR",cause="cache_accounting")
        self._cache[parsed.key]=record
        if cancelled is not None:
            raise cancelled
        return json.loads(record)["response"]
