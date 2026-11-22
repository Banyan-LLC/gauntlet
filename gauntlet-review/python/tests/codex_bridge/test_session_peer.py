"""The peer session server: codex_status/codex_review bound per call, one adapter bridge per binding."""
import asyncio
import json
import uuid

import pytest
pytest.importorskip("openai_codex")
from mcp import Client

from gauntlet_review import session
from gauntlet_review.codex_bridge import server as peer_server
from gauntlet_review.codex_bridge.engine import BridgeError, PeerReply

pytestmark = pytest.mark.anyio


class Peer:
    def __init__(self, config):
        self.config, self.calls, self.closed = config, 0, 0
        self.text, self.release, self.entered = "complete", None, asyncio.Event()

    async def run(self, prompt):
        self.calls += 1
        self.entered.set()
        if self.release:
            await self.release.wait()
        return PeerReply("thread-1", f"turn-{self.calls}", self.text)

    async def close(self):
        self.closed += 1


@pytest.fixture
def peers(monkeypatch):
    made = []

    def create(config):
        peer = Peer(config)
        made.append(peer)
        return peer
    monkeypatch.setattr(peer_server, "SdkConversation", create)
    return made


@pytest.fixture
def server(tmp_path):
    def make():
        return Client(session.create_peer_server(session.Resolver("peer", tmp_path / "state"), 10, False),
                      raise_exceptions=True)
    return make


def binding_of(work, branch="feature/x"):
    return {"checkout": str(work.resolve()), "repository_id": "owner-repo",
            "source_ref": f"refs/heads/{branch}", "target_ref": "refs/remotes/origin/main"}


async def call(client, tool, arguments):
    result = await client.call_tool(tool, arguments)
    assert json.loads(result.content[0].text) == result.structured_content
    return result.structured_content


async def test_both_tools_require_checkout(server, peers):
    async with server() as client:
        tools = {tool.name: tool for tool in (await client.list_tools()).tools}
        assert set(tools) == {"codex_status", "codex_review"}
        status_schema, review_schema = tools["codex_status"].input_schema, tools["codex_review"].input_schema
        assert status_schema["required"] == ["checkout"] and set(status_schema["properties"]) == {"checkout"}
        assert set(review_schema["properties"]) == {"instance_id", "key", "prompt", "expected_thread_id", "checkout"}
        assert "checkout" in review_schema["required"]
        assert all(schema["additionalProperties"] is False for schema in (status_schema, review_schema))
        missing = await call(client, "codex_status", {})
        assert missing["error"]["code"] == "INVALID_ARGUMENT" and missing["error"]["cause"] == "checkout_required"
        assert "current working folder" in missing["error"]["hint"] and missing["binding"] is None
        extra = await call(client, "codex_status", {"checkout": "/x", "model": "private-sdk-detail"})
        assert extra["error"]["code"] == "INVALID_ARGUMENT" and "private-sdk-detail" not in json.dumps(extra)
    assert peers == []                                     # no bridge, no conversation


async def test_status_then_one_turn_then_exact_replay(server, peers, make_checkout):
    work = make_checkout()
    async with server() as client:
        status = await call(client, "codex_status", {"checkout": str(work)})
        assert status["ok"] and status["state"] == "ready" and status["binding"] == binding_of(work)
        assert peers[0].calls == 0
        args = {"checkout": str(work), "instance_id": status["instance_id"], "key": "first", "prompt": "review",
                "expected_thread_id": None}
        first = await call(client, "codex_review", args)
        assert first["ok"] and first["text"] == "complete" and first["binding"] == binding_of(work)
        assert await call(client, "codex_review", args) == first and peers[0].calls == 1
    operator = peers[0].config.operator
    assert (operator.participant, operator.role, operator.repo_path) == ("claude-peer", "reviewer", work.resolve())
    assert peers[0].config.result_reserve > 0 and peers[0].config.timeout_seconds == 10


async def test_a_branch_switch_between_status_and_review_is_binding_changed(server, peers, make_checkout, run_git):
    work = make_checkout()
    async with server() as client:
        old = await call(client, "codex_status", {"checkout": str(work)})
        run_git(work, "checkout", "-q", "-b", "feature/y")
        changed = await call(client, "codex_review", {"checkout": str(work), "instance_id": old["instance_id"],
                                                      "key": "k", "prompt": "review", "expected_thread_id": None})
        assert changed["error"]["code"] == "BINDING_CHANGED" and changed["error"]["cause"] == "binding_changed"
        assert changed["binding"] == binding_of(work, "feature/y") and changed["instance_binding"] == binding_of(work)
        assert peers[0].calls == 0
        new = await call(client, "codex_status", {"checkout": str(work)})
        assert new["instance_id"] != old["instance_id"] and new["binding"] == binding_of(work, "feature/y")


async def test_an_unknown_instance_is_adapter_restarted(server, peers, make_checkout):
    work = make_checkout()
    async with server() as client:
        result = await call(client, "codex_review", {"checkout": str(work), "instance_id": "f" * 32, "key": "k",
                                                     "prompt": "review", "expected_thread_id": None})
    assert result["error"]["code"] == "ADAPTER_RESTARTED" and result["binding"] == binding_of(work)


async def test_each_checkout_gets_its_own_bridge_and_shutdown_closes_them(server, peers, make_checkout, run_git,
                                                                         tmp_path):
    work = make_checkout()
    other = tmp_path / "other"
    run_git(work, "worktree", "add", "-q", "-b", "feature/z", str(other))
    async with server() as client:
        a = await call(client, "codex_status", {"checkout": str(work)})
        b = await call(client, "codex_status", {"checkout": str(other)})
        assert a["instance_id"] != b["instance_id"] and b["binding"] == binding_of(other, "feature/z")
        assert [p.config.operator.repo_path for p in peers] == [work.resolve(), other.resolve()]
    assert [p.closed for p in peers] == [1, 1]


async def test_a_folder_outside_any_checkout_is_a_per_call_error(server, peers, make_checkout, tmp_path):
    plain = tmp_path / "plain"
    plain.mkdir()
    work = make_checkout()
    async with server() as client:
        refused = await call(client, "codex_status", {"checkout": str(plain)})
        assert refused["error"]["code"] == "NOT_A_GIT_CHECKOUT" and refused["binding"] is None
        assert "checkout" in refused["error"]["hint"] and peers == []
        assert (await call(client, "codex_status", {"checkout": str(work)}))["ok"]


async def test_replies_carry_the_binding_at_the_size_boundary(server, peers, make_checkout, monkeypatch):
    from gauntlet_review.codex_bridge.engine import TEXT_BYTES, mcp_result
    work = make_checkout()
    reserve = 3 * len(json.dumps({"binding": binding_of(work)}, ensure_ascii=False, separators=(",", ":")).encode()) + 64

    def fits(size):
        try:
            mcp_result({"ok": True, "thread_id": "thread-1", "turn_id": "turn-1", "text": "x" * size}, reserve)
            return True
        except BridgeError:
            return False
    low, high = 0, TEXT_BYTES
    while low < high:
        middle = (low + high + 1) // 2
        low, high = (middle, high) if fits(middle) else (low, middle - 1)
    async with server() as client:
        status = await call(client, "codex_status", {"checkout": str(work)})
        thread = None
        for size, key in ((low, "fits"), (low + 1, "over")):            # one conversation, two turns
            peers[0].text = "x" * size
            args = {"checkout": str(work), "instance_id": status["instance_id"], "key": key, "prompt": "review",
                    "expected_thread_id": thread}
            reply = await call(client, "codex_review", args)
            assert reply["binding"] == binding_of(work)
            if size == low:
                assert reply["ok"] and len(reply["text"]) == low
                assert await call(client, "codex_review", args) == reply        # exact replay keeps it too
                thread = reply["thread_id"]
            else:
                assert reply["error"]["code"] == "LIMIT_EXCEEDED"          # refused inside the adapter, bound
    assert binding_reserve_matches(work, reserve)


def binding_reserve_matches(work, reserve):
    return session.binding_reserve(binding_of(work)) == reserve


class FakeBridge:
    def __init__(self, key):
        self.key, self.instance_id, self._busy = key, uuid.uuid4().hex, False
        self.closes, self.gate, self.closed = 0, None, asyncio.Event()

    async def close(self):
        self.closes += 1
        if self.gate:
            await self.gate.wait()
        self.closed.set()
        return {"status": "succeeded", "cause": None}


class Made(list):
    def __call__(self, key):
        bridge = FakeBridge(key)
        self.append(bridge)
        return bridge


async def test_a_full_pool_evicts_the_least_recently_used_idle_bridge_or_refuses():
    made = Made()
    pool = session._PeerPool(made, 2)
    async with pool.lease("a"):
        pass
    async with pool.lease("b") as b:
        async with pool.lease("c") as c:                  # "a" was idle: evicted
            assert made[0].closes == 1 and set(pool.entries) == {"b", "c"}
            with pytest.raises(BridgeError) as full:
                async with pool.lease("d"):
                    pass
            assert full.value.code == "LIMIT_EXCEEDED" and full.value.cause == "bindings"
            assert pool.owner(b.instance_id) == "b" and pool.owner(made[0].instance_id) is None
    await pool.close()
    assert [bridge.closes for bridge in made] == [1, 1, 1]


async def test_overlapping_admissions_keep_the_bound_and_one_bridge_per_binding():
    made = Made()
    pool = session._PeerPool(made, 2)
    async with pool.lease("a"):
        pass
    made[0].gate = asyncio.Event()                        # "a" will be evicted with its close blocked
    hold = asyncio.Event()
    entered = []

    async def use(key):
        try:
            async with pool.lease(key) as bridge:
                entered.append((key, bridge))
                assert len(pool.entries) <= 2
                await hold.wait()
        except BridgeError as error:
            entered.append((key, error.code))
    held_b = asyncio.Event()

    async def keep_b():
        async with pool.lease("b"):
            held_b.set()
            await hold.wait()
    tasks = [asyncio.create_task(keep_b())]
    await held_b.wait()
    tasks += [asyncio.create_task(use(key)) for key in ("c", "d", "c")]
    await asyncio.sleep(0.05)
    assert entered == [] and made[0].closes == 1 and len(pool.entries) <= 2     # all wait behind the close
    made[0].gate.set()
    await asyncio.sleep(0.05)
    hold.set()
    await asyncio.gather(*tasks)
    keys = [key for key, _ in entered]
    assert sorted(keys) == ["c", "c", "d"]
    assert dict(entered)["d"] == "LIMIT_EXCEEDED"
    c_bridges = {id(value) for key, value in entered if key == "c"}
    assert len(c_bridges) == 1 and sum(bridge.key == "c" for bridge in made) == 1
    await pool.close()
    assert all(bridge.closes >= 1 for bridge in made) and not pool.closing


async def test_a_cancelled_review_releases_its_lease():
    made = Made()
    pool = session._PeerPool(made, 1)
    inside = asyncio.Event()

    async def review():
        async with pool.lease("a"):
            inside.set()
            await asyncio.Event().wait()
    task = asyncio.create_task(review())
    await inside.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert pool.entries["a"][1] == 0
    async with pool.lease("b"):                            # "a" became evictable
        assert made[0].closes == 1
    await pool.close()
    assert made[1].closes == 1


async def test_cancelling_the_evicting_call_never_abandons_the_close():
    made = Made()
    pool = session._PeerPool(made, 1)
    async with pool.lease("a"):
        pass
    made[0].gate = asyncio.Event()

    async def evict():
        async with pool.lease("b"):
            pass
    task = asyncio.create_task(evict())
    await asyncio.sleep(0.05)
    assert made[0].closes == 1 and len(pool.closing) == 1
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert "b" not in pool.entries and len(made) == 1      # nothing admitted for the cancelled call
    assert not made[0].closed.is_set() and len(pool.closing) == 1                # the close keeps running
    made[0].gate.set()
    await asyncio.wait_for(made[0].closed.wait(), 1)
    await asyncio.sleep(0)
    assert not pool.closing
    await pool.close()
    assert made[0].closes == 1                             # never closed twice


async def enter(pool, key):
    async with pool.lease(key):
        pass


async def cancel_an_eviction(pool, key):
    """Starts an admission that must evict, lets it block on the victim's close, and cancels it."""
    task = asyncio.create_task(enter(pool, key))
    await asyncio.sleep(0.05)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task


async def test_a_bridge_still_closing_keeps_its_capacity_slot(monkeypatch):
    from gauntlet_review.codex_bridge import engine
    monkeypatch.setattr(engine, "CLEANUP_SECONDS", 0)        # every bounded wait becomes one second
    made = Made()
    pool = session._PeerPool(made, 2)
    for key in ("a", "b"):
        await enter(pool, key)
    made[0].gate = asyncio.Event()                            # "a", least recently used, stalls while closing
    await cancel_an_eviction(pool, "c")
    assert set(pool.entries) == {"b"} and len(pool.closing) == 1
    with pytest.raises(BridgeError) as full:                  # "a" still holds its slot: no third live bridge
        await enter(pool, "d")
    assert full.value.code == "LIMIT_EXCEEDED" and full.value.cause == "bindings"
    assert "d" not in pool.entries and len(pool.entries) + len(pool.closing) <= 2
    made[0].gate.set()
    await asyncio.wait_for(made[0].closed.wait(), 1)
    await asyncio.sleep(0)
    async with pool.lease("d"):                               # the slot is free once the close has finished
        assert set(pool.entries) == {"b", "d"} and not pool.closing
    await pool.close()


@pytest.mark.parametrize("cancels", [1, 2, 3])
async def test_a_cancelled_shutdown_still_finishes_every_close(cancels):
    made = Made()
    pool = session._PeerPool(made, 2)
    for key in ("a", "b"):
        await enter(pool, key)
    gate = asyncio.Event()
    made[0].gate = made[1].gate = gate                        # a retiring bridge and a live one, both slow to close
    await cancel_an_eviction(pool, "c")
    assert set(pool.entries) == {"b"} and len(pool.closing) == 1
    closer = asyncio.create_task(pool.close())
    await asyncio.sleep(0.05)
    for _ in range(cancels):                                  # repeated native cancellation of the shutdown
        closer.cancel()
        await asyncio.sleep(0.03)
        assert not closer.done() or made[0].closed.is_set()
    asyncio.get_running_loop().call_later(0.1, gate.set)
    with pytest.raises(asyncio.CancelledError):
        await closer
    assert made[0].closed.is_set() and made[1].closed.is_set()   # teardown finished before cancellation went on
    assert not pool.closing and not pool.entries


async def test_shutdown_waits_for_closes_still_running():
    made = Made()
    pool = session._PeerPool(made, 1)
    async with pool.lease("a"):
        pass
    made[0].gate = asyncio.Event()

    async def evict():
        async with pool.lease("b"):
            pass
    task = asyncio.create_task(evict())
    await asyncio.sleep(0.05)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    closing = asyncio.create_task(pool.close())
    await asyncio.sleep(0.05)
    assert not closing.done()                             # shutdown waits for the running close
    made[0].gate.set()
    await closing
    assert made[0].closed.is_set() and not pool.closing
