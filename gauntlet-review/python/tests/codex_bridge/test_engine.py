"""Consumer contracts for admission, exact replay and uncertain native failures."""
import asyncio
from dataclasses import replace
import json

import pytest

from gauntlet_review import peer_model
from gauntlet_review.codex_bridge.engine import Bridge,BridgeConfig,BridgeError,ModelCheckRefusal,PeerReply

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
        self.checks=[]
        self.check_failure=None
        self.selections=[]

    async def check(self,selection):
        self.checks.append(selection)
        if self.check_failure:
            raise self.check_failure

    async def run(self,prompt,selection):
        self.calls+=1
        self.selections.append(selection)
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


BUILT_IN={"model":"gpt-6.1-sol","model_source":"built_in","effort":"xhigh","effort_source":"built_in"}


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
    assert first=={"ok":True,"thread_id":"fixture-thread","turn_id":"turn-1","text":"complete","peer_model":BUILT_IN}
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


async def test_busy_status_and_refusals_include_already_owned_native_thread(config):
    class Started(Conversation):
        async def run(self,prompt,selection):
            self.thread_id="fixture-thread"
            self.turn_id="turn-1"
            return await super().run(prompt,selection)
    peer=Started(); peer.release=asyncio.Event(); bridge=Bridge(config,peer)
    running=asyncio.create_task(bridge.call(request(bridge)))
    await peer.entered.wait()
    try:
        assert bridge.status()["thread_id"]=="fixture-thread"
        result=await bridge.call(request(bridge,"other"))
        assert result["error"]["thread_id"]=="fixture-thread"
        assert result["error"]["turn_id"]=="turn-1"
    finally:
        peer.release.set()
        await running


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


async def test_sdk_task_self_cancellation_returns_uncertain_receipt_without_cancelling_caller(config):
    peer=Conversation(failure=asyncio.CancelledError("private-prompt"))
    bridge=Bridge(config,peer); initial=request(bridge)
    result=await bridge.call(initial)
    refused(result,"SDK_FAILURE",uncertain=True,cleanup="succeeded")
    assert result["error"]["cause"]=="cancellation"
    assert asyncio.current_task().cancelling()==0
    assert await bridge.call(initial)==result and peer.calls==1 and peer.closed==1
    refused(await bridge.call(request(bridge,"new")),"POISONED",uncertain=True)


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


@pytest.mark.parametrize("timeout",[10,600,1800])
async def test_default_ceiling_keeps_the_status_shape(config,timeout):
    bridge=Bridge(replace(config,timeout_seconds=timeout),Conversation())
    assert set(bridge.status())=={"ok","instance_id","thread_id","state","peer_model"}


@pytest.mark.parametrize("timeout",[1801,5400])
async def test_over_the_default_ceiling_is_a_timeout_range_refusal(config,timeout):
    with pytest.raises(BridgeError) as error:
        Bridge(replace(config,timeout_seconds=timeout),Conversation())
    assert (error.value.code,error.value.cause)==("CONFIGURATION_ERROR","timeout_range")


@pytest.mark.parametrize("timeout",[10,1800,5400,7200])
async def test_extended_timeout_is_an_explicit_override_shown_in_status(config,timeout):
    bridge=Bridge(replace(config,timeout_seconds=timeout,extended_timeout=True),Conversation())
    status=bridge.status()
    assert status["extended_timeout"]=={"timeout_seconds":timeout,"max_seconds":7200}
    assert {key:status[key] for key in ("ok","thread_id","state")}=={"ok":True,"thread_id":None,"state":"ready"}


@pytest.mark.parametrize("timeout",[9,7201,10800])
async def test_extended_timeout_keeps_a_hard_upper_bound(config,timeout):
    with pytest.raises(BridgeError) as error:
        Bridge(replace(config,timeout_seconds=timeout,extended_timeout=True),Conversation())
    assert (error.value.code,error.value.cause)==("CONFIGURATION_ERROR","timeout_range")


@pytest.mark.parametrize("flag",[1,"yes",None])
async def test_extended_timeout_flag_is_strictly_boolean(config,flag):
    with pytest.raises(BridgeError) as error:
        Bridge(replace(config,timeout_seconds=600,extended_timeout=flag),Conversation())
    assert error.value.code=="CONFIGURATION_ERROR"


async def test_extended_timeout_reaches_the_turn_deadline(config,monkeypatch):
    from gauntlet_review.codex_bridge import engine
    waits=[]
    original=engine.asyncio.wait
    async def wait(tasks,timeout=None):
        waits.append(timeout)
        return await original(tasks,timeout=timeout)
    monkeypatch.setattr(engine.asyncio,"wait",wait)
    bridge=Bridge(replace(config,timeout_seconds=5400,extended_timeout=True),Conversation())
    assert (await bridge.call(request(bridge)))["ok"]
    # The turn wait is the whole deadline less the five-second cleanup reserve.
    assert 5394<waits[0]<=5395


@pytest.mark.parametrize("timeout, extended, expected",[
    (10,False,None),(1800,False,None),(5400,True,None),(7200,True,None),
    (1801,False,{"code":"TIMEOUT_OUT_OF_RANGE","accepted":{"min":10,"max":1800},
        "opt_in":{"flag":"--allow-extended-timeout","max":7200}}),
    (5400,False,{"code":"TIMEOUT_OUT_OF_RANGE","accepted":{"min":10,"max":1800},
        "opt_in":{"flag":"--allow-extended-timeout","max":7200}}),
    (9,False,{"code":"TIMEOUT_OUT_OF_RANGE","accepted":{"min":10,"max":1800}}),
    (7201,True,{"code":"TIMEOUT_OUT_OF_RANGE","accepted":{"min":10,"max":7200}}),
    (9,True,{"code":"TIMEOUT_OUT_OF_RANGE","accepted":{"min":10,"max":7200}}),
])
async def test_timeout_refusal_is_structured_and_says_how_to_opt_in(timeout,extended,expected):
    from gauntlet_review.codex_bridge.engine import timeout_refusal
    assert timeout_refusal(timeout,extended)==expected


async def test_operator_cannot_use_author_role_or_relative_paths(config):
    from pathlib import Path
    for operator in (replace(config.operator,role="author"),replace(config.operator,repo_path=Path("relative"))):
        with pytest.raises(BridgeError) as error:
            Bridge(replace(config,operator=operator),Conversation())
        assert error.value.code=="CONFIGURATION_ERROR"


def settings_mode(config,tmp_path):
    return replace(config,model_settings_root=tmp_path/"model-root")


def write_settings(root,document):
    root.mkdir(parents=True,exist_ok=True)
    (root/peer_model.SETTINGS_NAME).write_text(document if isinstance(document,str) else json.dumps(document))


async def test_status_reports_the_selection_for_each_mode(config,tmp_path):
    assert Bridge(config,Conversation()).status()["peer_model"]==BUILT_IN
    assert Bridge(replace(config,model="gpt-6-sol"),Conversation()).status()["peer_model"]=={
        "model":"gpt-6-sol","model_source":"operator","effort":"xhigh","effort_source":"built_in"}
    settings=settings_mode(config,tmp_path)
    write_settings(settings.model_settings_root,{"version":1,"default":{"effort":"max"},
        "repositories":{"fixture":{"model":"gpt-6-astra"}}})
    bridge=Bridge(settings,Conversation())
    assert bridge.status()["peer_model"]=={"model":"gpt-6-astra","model_source":"repository",
        "effort":"max","effort_source":"global"}
    write_settings(settings.model_settings_root,"{not json")
    status=bridge.status()
    assert status["ok"] is True and status["peer_model"]=={"error":"MODEL_SETTINGS_INVALID"}


async def test_a_switch_between_turns_reaches_the_next_turn(config,tmp_path):
    settings=settings_mode(config,tmp_path); root=settings.model_settings_root
    peer=Conversation(); bridge=Bridge(settings,peer)
    first=await bridge.call(request(bridge))
    peer_model.save(root,peer_model.with_fields(peer_model.EMPTY,"fixture",model="gpt-6-sol",effort="high"))
    second=await bridge.call(request(bridge,"second",thread="fixture-thread"))
    assert [s.public() for s in peer.selections]==[BUILT_IN,{"model":"gpt-6-sol","model_source":"repository",
        "effort":"high","effort_source":"repository"}]
    assert peer.checks==peer.selections
    assert first["peer_model"]==BUILT_IN and second["peer_model"]["model"]=="gpt-6-sol"
    assert second["peer_model"]["effort"]=="high"


async def test_an_invalid_settings_file_refuses_cleanly(config,tmp_path):
    settings=settings_mode(config,tmp_path); root=settings.model_settings_root
    write_settings(root,'{"version":1,"default":{"effort":"High"}}')
    peer=Conversation(); bridge=Bridge(settings,peer); initial=request(bridge)
    result=await bridge.call(initial)
    refused(result,"MODEL_SETTINGS_INVALID")
    assert result["error"]["cause"]=="model_settings"
    assert peer.calls==0 and peer.checks==[] and bridge.status()["state"]=="ready"
    write_settings(root,{"version":1,"default":{"effort":"high"}})
    retried=await bridge.call(initial)
    assert retried["ok"] and retried["peer_model"]["effort"]=="high" and peer.calls==1


@pytest.mark.parametrize("code",["MODEL_UNAVAILABLE","EFFORT_NOT_SUPPORTED","CATALOG_UNAVAILABLE"])
async def test_catalog_refusals_are_certain_and_recoverable(config,code):
    peer=Conversation(); peer.check_failure=ModelCheckRefusal(code,cause="model_check")
    bridge=Bridge(config,peer); initial=request(bridge)
    result=await bridge.call(initial)
    refused(result,code)
    assert result["error"]["cause"]=="model_check"
    assert peer.calls==0 and peer.closed==0 and bridge.status()["state"]=="ready"
    peer.check_failure=None
    retried=await bridge.call(initial)
    assert retried["ok"] and retried["thread_id"]=="fixture-thread" and peer.calls==1 and peer.closed==0


async def test_a_failing_check_poisons_as_today(config):
    peer=Conversation(); peer.check_failure=RuntimeError("private-prompt")
    bridge=Bridge(config,peer); initial=request(bridge)
    result=await bridge.call(initial)
    refused(result,"SDK_FAILURE",uncertain=True,cleanup="succeeded")
    assert peer.calls==0 and peer.closed==1 and bridge.status()["state"]=="poisoned"
    assert await bridge.call(initial)==result


async def test_a_model_check_refusal_from_run_is_not_certain(config):
    peer=Conversation(failure=ModelCheckRefusal("MODEL_UNAVAILABLE",cause="model_check"))
    bridge=Bridge(config,peer)
    result=await bridge.call(request(bridge))
    assert result["error"]["uncertain"] is True and bridge.status()["state"]=="poisoned" and peer.closed==1


async def test_replay_after_a_switch_returns_the_original_model(config,tmp_path):
    settings=settings_mode(config,tmp_path); root=settings.model_settings_root
    peer=Conversation(); bridge=Bridge(settings,peer); initial=request(bridge)
    first=await bridge.call(initial)
    peer_model.save(root,peer_model.with_fields(peer_model.EMPTY,None,model="gpt-6-sol"))
    assert await bridge.call(initial)==first and first["peer_model"]==BUILT_IN and peer.calls==1


@pytest.mark.parametrize("change",[{"effort":"High"},{"effort":7},{"model":"m","model_settings_root":"ROOT"},
    {"effort":"high","model_settings_root":"ROOT"},{"model_settings_root":"relative"},{"model_settings_root":"text"}],
    ids=["bad-effort","effort-type","settings-with-model","settings-with-effort","relative-root","root-not-path"])
async def test_configuration_refusals(config,tmp_path,change):
    from pathlib import Path
    values={key:(tmp_path if value=="ROOT" else Path("relative") if value=="relative" else value)
        for key,value in change.items()}
    with pytest.raises(BridgeError) as error:
        Bridge(replace(config,**values),Conversation())
    assert error.value.code=="CONFIGURATION_ERROR"


def largest_text(reserve):
    """The longest final text mcp_result admits for a successful turn under this reserve."""
    from gauntlet_review.codex_bridge.engine import TEXT_BYTES,mcp_result

    def fits(size):
        try:
            # A completed reply also names the peer model it used (the built-in default here).
            mcp_result({"ok":True,"thread_id":"fixture-thread","turn_id":"turn-1","text":"x"*size,
                "peer_model":BUILT_IN},reserve)
            return True
        except BridgeError:
            return False
    low,high=0,TEXT_BYTES
    while low<high:
        middle=(low+high+1)//2
        low,high=(middle,high) if fits(middle) else (low,middle-1)
    return low


async def test_a_result_reserve_lowers_what_one_turn_may_return(config):
    reserve=4096
    size=largest_text(reserve)
    assert 0<size<largest_text(0)
    fits=Bridge(replace(config,result_reserve=reserve),Conversation(text="x"*size))
    assert (await fits.call(request(fits)))["ok"]
    over=Bridge(replace(config,result_reserve=reserve),Conversation(text="x"*(size+1)))
    result=await over.call(request(over))
    assert result["ok"] is False and result["error"]["code"]=="LIMIT_EXCEEDED"
    unchanged=Bridge(config,Conversation(text="x"*(size+1)))           # the default reserve is zero
    assert (await unchanged.call(request(unchanged)))["ok"]


@pytest.mark.parametrize("reserve",[-1,256*1024//4+1,True,"64",None])
def test_an_invalid_result_reserve_is_a_configuration_error(config,reserve):
    with pytest.raises(BridgeError) as error:
        Bridge(replace(config,result_reserve=reserve),Conversation())
    assert error.value.code=="CONFIGURATION_ERROR"



@pytest.mark.parametrize("failure",["deep","root"])
async def test_unreadable_settings_refuse_cleanly_and_recover(config,tmp_path,monkeypatch,failure):
    # R4-F1: parser exhaustion and filesystem errors are MODEL_SETTINGS_INVALID, never an escaping exception.
    settings=settings_mode(config,tmp_path); root=settings.model_settings_root
    if failure=="deep":
        write_settings(root,"[" * 30000 + "]" * 30000)
    else:
        write_settings(root,{"version":1,"default":{"effort":"high"}})
        from gauntlet_review import launch
        original=launch.check_unredirected
        def unreadable(path):
            raise PermissionError("access denied")
        monkeypatch.setattr(launch,"check_unredirected",unreadable)
    peer=Conversation(); bridge=Bridge(settings,peer); initial=request(bridge)
    assert bridge.status()["peer_model"]=={"error":"MODEL_SETTINGS_INVALID"}
    refused(await bridge.call(initial),"MODEL_SETTINGS_INVALID")
    assert peer.calls==0 and peer.checks==[] and bridge.status()["state"]=="ready"
    if failure=="deep":
        write_settings(root,{"version":1,"default":{"effort":"high"}})
    else:
        monkeypatch.setattr(launch,"check_unredirected",original)
    retried=await bridge.call(initial)
    assert retried["ok"] and retried["peer_model"]["effort"]=="high" and peer.calls==1
