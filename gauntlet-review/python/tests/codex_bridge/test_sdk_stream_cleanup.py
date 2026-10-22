"""SDK stream cleanup must preserve primary failures and truthful cleanup receipts."""
import asyncio
import json

import pytest

pytest.importorskip("openai_codex")
from openai_codex.errors import JsonRpcError

from gauntlet_review.codex_bridge import sdk
from gauntlet_review.codex_bridge.engine import Bridge, BridgeError
from .test_sdk import Handle, conversation, message, terminal

pytestmark = pytest.mark.anyio


class ClosingStream:
    """Replace only the external SDK stream boundary, retaining actual iteration."""
    def __init__(self, source, failure):
        self.source, self.failure = source, failure

    def __aiter__(self):
        return self

    async def __anext__(self):
        return await self.source.__anext__()

    async def aclose(self):
        await self.source.aclose()
        raise self.failure


def failing_stream(monkeypatch, failure):
    original = Handle.stream
    monkeypatch.setattr(Handle, "stream", lambda self: ClosingStream(original(self), failure))


@pytest.mark.parametrize("events,code,cause", [
    ([message()], "MISSING_TERMINAL", "unterminated_stream"),
    ([terminal()], "INVALID_FINAL_MESSAGE", "missing_final"),
    ([message(), terminal(status="failed")], "TURN_FAILED", "terminal_failure"),
    ([JsonRpcError(-1, "private-rpc")], "SDK_FAILURE", "rpc"),
    ([UnicodeError("private-unicode")], "INVALID_FINAL_MESSAGE", "invalid_final"),
    ([OSError("private-stream")], "SDK_FAILURE", "sdk"),
    ([asyncio.CancelledError("private-cancel")], "SDK_FAILURE", "cancellation"),
])
async def test_stream_close_failure_preserves_primary_and_reports_failed_cleanup(
        config, monkeypatch, events, code, cause):
    # Removing primary preservation makes these return generic sdk/close failure.
    failing_stream(monkeypatch, OSError("private-close"))
    peer, native = conversation(config, monkeypatch, events)
    bridge = Bridge(config, peer)
    request = {"instance_id": bridge.instance_id, "key": "first", "prompt": "review",
               "expected_thread_id": None}
    result = await bridge.call(request)
    assert result["ok"] is False
    error = result["error"]
    assert (error["code"], error["cause"]) == (code, cause)
    assert error["cleanup"] == {"status": "failed", "cause": "cleanup_failure"}
    assert error["uncertain"] and error["partial_usable"] is False
    assert "private-" not in json.dumps(result)
    assert native.closed and native.handles[0].closed
    assert bridge.status()["state"] == "poisoned"
    assert await bridge.call(request) == result


async def test_event_limit_is_not_replaced_by_stream_close_failure(config, monkeypatch):
    failing_stream(monkeypatch, OSError("private-close"))
    monkeypatch.setattr(sdk, "EVENT_BYTES", 0)
    peer, native = conversation(config, monkeypatch, [message(), terminal()])
    bridge = Bridge(config, peer)
    result = await bridge.call({"instance_id": bridge.instance_id, "key": "first",
                               "prompt": "review", "expected_thread_id": None})
    assert (result["error"]["code"], result["error"]["cause"]) == ("LIMIT_EXCEEDED", "event_limit")
    assert result["error"]["cleanup"]["status"] == "failed"
    assert native.closed and native.handles[0].interrupted


async def test_successful_terminal_with_failed_stream_close_is_unusable(config, monkeypatch):
    failing_stream(monkeypatch, OSError("private-close"))
    peer, native = conversation(config, monkeypatch, [message(), terminal()])
    bridge = Bridge(config, peer)
    result = await bridge.call({"instance_id": bridge.instance_id, "key": "first",
                               "prompt": "review", "expected_thread_id": None})
    assert result["ok"] is False and result["error"]["code"] == "CLEANUP_FAILURE"
    assert result["error"]["cause"] == "stream_close_failure"
    assert result["error"]["cleanup"]["status"] == "failed"
    assert result["error"]["partial_usable"] is False and native.closed


async def test_stream_cleanup_keeps_typed_primary_and_both_underlying_errors(config, monkeypatch):
    original = JsonRpcError(-1, "private-rpc")
    cleanup = OSError("private-close")
    failing_stream(monkeypatch, cleanup)
    peer, native = conversation(config, monkeypatch, [original])
    with pytest.raises(BridgeError) as caught:
        await peer.run("review")
    assert (caught.value.code, caught.value.cause) == ("SDK_FAILURE", "rpc")
    assert isinstance(caught.value.__cause__, ExceptionGroup)
    assert list(caught.value.__cause__.exceptions) == [original, cleanup]
    with pytest.raises(BridgeError):
        await peer.close()
    assert native.closed


async def test_stream_cleanup_does_not_replace_cancellation(config, monkeypatch):
    original = asyncio.CancelledError("private-cancel")
    cleanup = OSError("private-close")
    failing_stream(monkeypatch, cleanup)
    peer, native = conversation(config, monkeypatch, [original])
    with pytest.raises(asyncio.CancelledError) as caught:
        await peer.run("review")
    assert caught.value is original
    assert cleanup is caught.value.__cause__
    with pytest.raises(BridgeError):
        await peer.close()
    assert native.closed


async def test_stream_interrupt_and_client_close_failures_are_all_retained(config, monkeypatch):
    stream_failure = OSError("private-stream-close")
    interrupt_failure = JsonRpcError(-1, "private-interrupt")
    client_failure = OSError("private-client-close")
    failing_stream(monkeypatch, stream_failure)
    peer, native = conversation(config, monkeypatch, [message()])
    with pytest.raises(BridgeError):
        await peer.run("review")

    async def interrupt():
        raise interrupt_failure

    native.handles[0].interrupt = interrupt
    native.close_failure = client_failure
    with pytest.raises(BridgeError) as caught:
        await peer.close()
    assert native.closed
    combined = caught.value.__cause__
    assert isinstance(combined, ExceptionGroup)
    assert [item.cause for item in combined.exceptions] == [
        "stream_close_failure", "interrupt_failure", "close_failure"]
    assert [item.__cause__ for item in combined.exceptions] == [
        stream_failure, interrupt_failure, client_failure]
