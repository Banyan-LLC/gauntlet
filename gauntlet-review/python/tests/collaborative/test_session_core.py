"""The core session server: the four author tools, a binding derived from `checkout` on every call."""
import asyncio
import json

import jsonschema
import pytest

from gauntlet_review import launch, session
from gauntlet_review.collaborative.contracts import encode

pytestmark = pytest.mark.anyio


def commit_file(run_git, work, name, body, message="change"):
    (work / name).write_bytes(body)
    run_git(work, "add", name)
    run_git(work, "commit", "-q", "-m", message)


@pytest.fixture
def server(tmp_path):
    from mcp import Client

    def make(root=None):
        return Client(session.create_core_server(session.Resolver("core", root or tmp_path / "state")),
                      raise_exceptions=True)
    return make


async def call(client, tool, request, checkout=session.MISSING):
    arguments = {"request": request}
    if checkout is not session.MISSING:
        arguments["checkout"] = str(checkout)
    result = await client.call_tool(tool, arguments)
    assert result.content[0].text == encode(result.structured_content).decode("utf-8")
    return result


def binding_of(work, branch="feature/x"):
    return {"checkout": str(work.resolve()), "repository_id": "owner-repo",
            "source_ref": f"refs/heads/{branch}", "target_ref": "refs/remotes/origin/main"}


async def test_tools_are_the_author_tools_and_require_checkout(server):
    async with server() as client:
        tools = (await client.list_tools()).tools
    assert {tool.name for tool in tools} == {"open_review", "read_review", "record_evidence", "review_status"}
    for tool in tools:
        schema = tool.input_schema
        jsonschema.Draft202012Validator.check_schema(schema)
        assert set(schema["properties"]) == {"request", "checkout"}
        assert sorted(schema["required"]) == ["checkout", "request"]
        assert schema["additionalProperties"] is False and schema["properties"]["checkout"]["type"] == "string"
        assert "checkout" in tool.description


async def test_a_full_author_cycle_carries_the_binding_and_uses_the_launchers_store(server, make_checkout, run_git,
                                                                                     tmp_path):
    work = make_checkout()
    commit_file(run_git, work, "b.txt", b"two\n")
    async with server() as client:
        status = await call(client, "review_status", {}, work)
        assert status.structured_content["ok"] and status.structured_content["binding"] == binding_of(work)
        opened = (await call(client, "open_review", {"key": "first", "expected_version": 0}, work)).structured_content
        assert opened["ok"] and opened["binding"] == binding_of(work)
        ids = {k: opened[k] for k in ("review_id", "revision_id", "snapshot_digest")}
        evidence = await call(client, "record_evidence", {"key": "ev", "expected_version": opened["store_version"], **ids,
            "origin": "agent_report", "command": "pytest", "runtime": "local", "exit_status": 0,
            "content": {"kind": "inline", "data_b64": "b2s="}}, work)
        assert evidence.structured_content["ok"], evidence.structured_content["error"]
        listing = (await call(client, "read_review", {**ids, "view": "manifest"}, work)).structured_content
        assert listing["ok"] and listing["binding"] == binding_of(work) and listing["result"]["complete"]
        again = (await call(client, "review_status", {"review_id": opened["review_id"]}, work)).structured_content
        assert again["result"]["counts"]["revisions"] == 1
    store = launch.derive(work, tmp_path / "state").state_dir
    assert (store / "collaborative-v1.sqlite3").is_file()


async def test_a_branch_switch_binds_the_new_branch_without_a_restart(server, make_checkout, run_git):
    work = make_checkout()
    commit_file(run_git, work, "b.txt", b"two\n")
    async with server() as client:
        opened = (await call(client, "open_review", {"key": "first", "expected_version": 0}, work)).structured_content
        assert opened["ok"]
        run_git(work, "checkout", "-q", "-b", "feature/y")
        other = (await call(client, "review_status", {}, work)).structured_content
        assert other["binding"] == binding_of(work, "feature/y") and other["result"]["series"] is None
        run_git(work, "checkout", "-q", "feature/x")
        back = (await call(client, "review_status", {}, work)).structured_content
        assert back["binding"] == binding_of(work) and back["result"]["series"]["id"] == opened["review_id"]


async def test_one_server_serves_a_linked_worktree_and_the_main_checkout(server, make_checkout, run_git, tmp_path):
    work = make_checkout()
    other = tmp_path / "other"
    run_git(work, "worktree", "add", "-q", "-b", "feature/z", str(other))
    async with server() as client:
        worktree = (await call(client, "review_status", {}, other)).structured_content
        main = (await call(client, "review_status", {}, work)).structured_content
    assert worktree["binding"] == {**binding_of(other, "feature/z")}
    assert main["binding"] == binding_of(work)


async def test_the_servers_own_folder_does_not_matter(server, make_checkout, tmp_path, monkeypatch):
    work = make_checkout()
    plain = tmp_path / "plain"
    plain.mkdir()
    monkeypatch.chdir(plain)                               # started outside any checkout
    async with server() as client:
        assert len((await client.list_tools()).tools) == 4
        ok = (await call(client, "review_status", {}, work)).structured_content
        assert ok["ok"] and ok["binding"] == binding_of(work)
        refused = await call(client, "review_status", {}, plain)
    body = refused.structured_content
    assert refused.is_error and body["binding"] is None and body["error"]["code"] == "NOT_A_GIT_CHECKOUT"
    assert body["error"]["retryable"] is True and "checkout" in body["error"]["detail"]["hint"]
    assert str(plain) not in refused.content[0].text


async def test_a_detached_head_is_a_per_call_error_until_a_branch_exists(server, make_checkout, run_git):
    work = make_checkout()
    run_git(work, "checkout", "-q", "--detach")
    async with server() as client:
        refused = (await call(client, "review_status", {}, work)).structured_content
        assert refused["error"]["code"] == "DETACHED_HEAD" and refused["binding"] is None
        run_git(work, "switch", "-q", "-c", "fix/z")
        ok = (await call(client, "review_status", {}, work)).structured_content
        assert ok["ok"] and ok["binding"]["source_ref"] == "refs/heads/fix/z"


@pytest.mark.parametrize("arguments, reason", [
    ({"request": {}}, "checkout_required"),
    ({"request": {}, "checkout": None}, "checkout_required"),
    ({"request": {}, "checkout": "relative/private-path-value"}, "invalid_checkout"),
    ({"request": {}, "checkout": 7}, "invalid_checkout"),
    ({"request": {}, "checkout": "C:\\x" if __import__("os").name == "nt" else "/x", "role": "reviewer"},
     "invalid_request"),
    ({"request": {"approved": True}, "checkout": "C:\\x" if __import__("os").name == "nt" else "/x"}, "invalid_request"),
])
async def test_invalid_arguments_are_refused_without_echoing_them(server, arguments, reason):
    async with server() as client:
        result = await client.call_tool("review_status", arguments)
    body = result.structured_content
    assert result.is_error and body["error"]["code"] == "INVALID_ARGUMENT" and body["binding"] is None
    assert body["error"]["detail"]["reason"] == reason
    assert "private-path-value" not in result.content[0].text
    if reason == "checkout_required":
        assert "current working folder" in body["error"]["detail"]["hint"]


async def test_unknown_tools_stay_protocol_errors(server):
    from mcp.shared.exceptions import MCPError
    async with server() as client:
        for name in ("submit_review", "bogus"):
            with pytest.raises(MCPError):
                await client.call_tool(name, {"request": {}, "checkout": "/x"})


async def test_the_pool_closes_the_least_recently_used_idle_core_beyond_its_bound(server, make_checkout, monkeypatch):
    from gauntlet_review.collaborative import core as module
    closed = []
    real = module.ReviewCore.close

    def watch(self):
        closed.append(self.config.repo_path)
        return real(self)
    monkeypatch.setattr(module.ReviewCore, "close", watch)
    monkeypatch.setattr(session, "CORE_BINDINGS", 2)
    a, b, c = make_checkout("a"), make_checkout("b"), make_checkout("c")
    async with server() as client:
        for work in (a, b, a, c):                          # b is now the least recently used
            assert (await call(client, "review_status", {}, work)).structured_content["ok"]
        assert closed == [b.resolve()]
    assert sorted(closed[1:]) == sorted([a.resolve(), c.resolve()])   # shutdown closes the rest


class FakeCore:
    def __init__(self, key):
        self.key, self.closed = key, False

    def close(self):
        self.closed = True


def test_a_full_pool_of_cores_in_use_is_busy():
    from gauntlet_review.collaborative.contracts import CoreError
    pool = session._CorePool(FakeCore, 2)
    first, second = pool.acquire("a"), pool.acquire("b")
    with pytest.raises(CoreError) as busy:
        pool.acquire("c")
    assert busy.value.code == "BUSY" and busy.value.retryable
    pool.release("a")
    third = pool.acquire("c")
    assert first.closed and not second.closed and not third.closed
    assert pool.acquire("b") is second                     # same binding, same core
    pool.close()
    assert second.closed and third.closed


async def test_a_cancelled_call_releases_its_lease():
    pool = session._CorePool(FakeCore, 1)
    entered = asyncio.Event()

    async def hold():
        with pool.lease("a"):
            entered.set()
            await asyncio.Event().wait()
    task = asyncio.create_task(hold())
    await entered.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert pool.entries["a"][1] == 0
    replacement = pool.acquire("b")                        # "a" was evictable again
    assert not replacement.closed and "a" not in pool.entries
    pool.close()
    assert replacement.closed


async def test_every_reply_carries_its_binding_up_to_the_size_limit(server, make_checkout, run_git, monkeypatch):
    from gauntlet_review.collaborative import server as core_server
    from gauntlet_review.collaborative.contracts import Policy
    work = make_checkout()
    commit_file(run_git, work, "big.bin", bytes(range(256)) * 300)                 # 76,800 bytes
    async with server() as client:
        opened = (await call(client, "open_review", {"key": "first", "expected_version": 0}, work)).structured_content
        replay = (await call(client, "open_review", {"key": "first", "expected_version": 0}, work)).structured_content
        assert replay["binding"] == binding_of(work) and replay["result"]["event_id"] == opened["result"]["event_id"]
        ids = {k: opened[k] for k in ("review_id", "revision_id", "snapshot_digest")}
        rows = (await call(client, "read_review", {**ids, "view": "manifest"}, work)).structured_content
        artifact = next(row["new_artifact"]["artifact_id"] for row in rows["result"]["items"] if row["new_artifact"])
        page = (await call(client, "read_review", {**ids, "view": "artifact", "artifact_id": artifact,
                                                   "length": 65536}, work)).structured_content
        assert page["ok"] and page["result"]["length"] == 65536 and page["binding"] == binding_of(work)
        # The largest artifact page still fits with a maximal binding: every checkout character and every ref
        # character needing a JSON escape.
        widest = {"checkout": "\\" * session.CHECKOUT_BYTES, "repository_id": "x" * 64,
                  "source_ref": "refs/heads/" + '"' * 1013, "target_ref": "refs/remotes/" + '"' * 1011}
        assert core_server.tool_result({**page, "binding": widest}, Policy().mcp_result_bytes) is not None
        real = core_server.tool_result
        monkeypatch.setattr(core_server, "tool_result",
                            lambda payload, limit: real(payload, len(json.dumps(payload)) // 2 if payload["ok"] else limit))
        over = (await call(client, "read_review", {**ids, "view": "manifest"}, work)).structured_content
    assert over["error"]["code"] == "LIMIT_EXCEEDED" and over["binding"] == binding_of(work)
