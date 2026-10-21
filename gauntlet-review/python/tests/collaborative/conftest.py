import pytest

pytest.importorskip("mcp")
pytest.importorskip("dulwich")
pytest.importorskip("pydantic")


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
def valid_open_payload():
    return {"key": "initial", "expected_version": 0}


@pytest.fixture
def cfg(tmp_path):
    from dulwich.repo import Repo
    from gauntlet_review.collaborative.contracts import OperatorConfig
    repo = tmp_path / "repo"
    repo.mkdir()
    Repo.init(str(repo)).close()
    state = tmp_path / "state"
    state.mkdir(mode=0o700)
    return OperatorConfig(repo, state, "fixture", b"refs/heads/topic", b"refs/heads/main",
                          "author", "author")


class GitFixture:
    def __init__(self, config):
        from dulwich.repo import Repo
        self.config = config
        self.repo = Repo(str(config.repo_path))
        self.counter = 0

    def commit(self, files, parents=None):
        from dulwich.objects import Blob, Commit, Tree
        nested = {}
        for path, (mode, body) in files.items():
            parts = path.split(b"/")
            current = nested
            for part in parts[:-1]:
                current = current.setdefault(part, {})
            if mode == 0o160000:
                oid = body.encode("ascii") if isinstance(body, str) else body
            else:
                blob = Blob.from_string(body)
                self.repo.object_store.add_object(blob)
                oid = blob.id
            current[parts[-1]] = mode, oid

        def tree(entries):
            result = Tree()
            for name, value in entries.items():
                mode, oid = (0o040000, tree(value)) if isinstance(value, dict) else value
                result.add(name, mode, oid)
            self.repo.object_store.add_object(result)
            return result.id

        self.counter += 1
        commit = Commit()
        commit.tree = tree(nested)
        commit.parents = [p.encode("ascii") for p in (parents or [])]
        commit.author = commit.committer = b"Fixture <fixture@example.invalid>"
        commit.author_time = commit.commit_time = self.counter
        commit.author_timezone = commit.commit_timezone = 0
        commit.message = f"fixture {self.counter}\n".encode("ascii")
        self.repo.object_store.add_object(commit)
        return commit.id.decode("ascii")

    def set_ref(self, ref, oid):
        self.repo.refs[ref] = oid.encode("ascii")

    def write_worktree_file(self, path, data):
        target = self.config.repo_path / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    def pair(self, old, new):
        base = self.commit(old)
        head = self.commit(new, parents=[base])
        self.set_ref(self.config.target_ref, base)
        self.set_ref(self.config.source_ref, head)
        self.repo.refs.set_symbolic_ref(b"HEAD", self.config.target_ref)
        return base, head


@pytest.fixture
def git_fixture(cfg):
    fixture = GitFixture(cfg)
    try:
        yield fixture
    finally:
        fixture.repo.close()


@pytest.fixture
def store(cfg,git_fixture):
    from gauntlet_review.collaborative.source import GitSource
    from gauntlet_review.collaborative.store import Store
    git_fixture.pair({}, {b"file":(0o100644,b"one")})
    with GitSource(cfg) as source:
        with Store.open(cfg,source.repo_binding) as value:
            yield value


@pytest.fixture
def append_event(cfg):
    """Real admission builder; never updates state or counters outside Store."""
    from dataclasses import asdict
    import hashlib
    import uuid
    from gauntlet_review.collaborative.contracts import Event,Mutation,encode
    from gauntlet_review.collaborative.source import GitSource,snapshot_payload

    async def append(store,*,key="once",expected_version=0,operation="open_review",body=None,
                     checkpoint=None,build_hook=None):
        config=store.config
        request={"key":key,"expected_version":expected_version,"operation":operation,
                 "body_sha256":None if body is None else hashlib.sha256(body).hexdigest()}
        request_digest=hashlib.sha256(encode({"scope":config.series_scope,"role":config.role,
            "policy_digest":store.policy.digest,"request":request})).hexdigest()
        async def build(view):
            if build_hook:
                build_hook(view)
            with GitSource(config) as source:
                snap=source.capture(store.policy)
                observation=asdict(source.observe())
            review_id=view.series.id if view.series else uuid.uuid4().hex
            revision_id=(view.series.current_revision if operation != "open_review" and view.series
                         else uuid.uuid4().hex)
            event_id=uuid.uuid4().hex
            data={"snapshot":{**snapshot_payload(snap),"digest":snap.digest},"observation":observation}
            if operation == "record_evidence":
                data={"evidence_id":uuid.uuid4().hex,"producer":config.participant,"origin":"agent_report",
                      "command":"fixture","runtime":"Python","exit_status":0,"observation":observation,
                      "content":{"kind":"inline","length":len(body),"sha256":hashlib.sha256(body).hexdigest(),
                                 "bytes_verified":True,"claims_verified":False}}
            content={"review_id":review_id,"revision_id":revision_id,"snapshot_digest":snap.digest,
                     "series_scope":config.series_scope,"request_digest":request_digest,"data":data}
            event_bytes=encode(content)
            event=Event(event_id,len(view.series.events)+1 if view.series else 1,revision_id,operation,
                        event_bytes,hashlib.sha256(event_bytes).hexdigest(),view.store_version+1)
            operation_result={"accepted":True,"change_count":len(snap.changes),"manifest_digest":snap.digest}
            if operation == "record_evidence":
                operation_result={"accepted":True,"evidence_id":data["evidence_id"],"producer":data["producer"],
                                  "origin":data["origin"],"content":data["content"]}
            receipt=encode({"event_id":event_id,"operation":operation,"review_id":review_id,
                "revision_id":revision_id,"snapshot_digest":snap.digest,"series_scope":config.series_scope,
                "request_digest":request_digest,"store_version":view.store_version+1,
                "observation":observation,"result":operation_result})
            return Mutation(event,body,receipt)
        async def noop():
            pass
        return await store.mutate(config.series_scope,config.participant,operation,key,request_digest,
                                  expected_version,build,checkpoint or noop)
    return append


@pytest.fixture
def verdict_factory():
    from gauntlet_review.collaborative.contracts import validate_request
    def make(history,*,disposition="addressed",reason="verified against pinned source",**overrides):
        value={"key":f"round_{history.verdict_count+1}","expected_version":history.store_version,
               "review_id":history.id,"revision_id":history.current_revision,
               "snapshot_digest":history.snapshot.digest,"verdict":"approve","summary":"reviewed",
               "recommendations":[],"coverage_digest":history.snapshot.digest,
               "coverage":[change.change_id for change in history.snapshot.changes],
               "carryover":[{"id":finding["record"]["id"],"digest":finding["digest"],
                             "status":disposition,"reason":reason} for finding in history.findings]}
        value.update(overrides)
        return validate_request("submit_review",value)
    return make


@pytest.fixture
def append_verdict(verdict_factory):
    from dataclasses import asdict,replace
    import hashlib
    import uuid
    from gauntlet_review.collaborative.contracts import Event,Mutation,encode
    from gauntlet_review.collaborative.source import GitSource
    def imports():
        from gauntlet_review.collaborative.policy import prepare_verdict
        from gauntlet_review.collaborative.store import Store
        return prepare_verdict,Store
    async def append(store,**options):
        prepare_verdict,Store=imports()
        config=replace(store.config,participant="peer",role="reviewer")
        request=verdict_factory(store.read_series(),**options)
        digest=hashlib.sha256(encode({"scope":config.series_scope,"role":config.role,
            "policy_digest":store.policy.digest,"request":request.model_dump(mode="json")})).hexdigest()
        async def build(view):
            history=view.series
            accepted=prepare_verdict(history,request,history.snapshot)
            with GitSource(config) as source:
                observation=asdict(source.check_snapshot(history.snapshot))
            event_id=uuid.uuid4().hex
            data={"accepted_round":history.verdict_count+1,"reviewer":config.participant,
                  "requested_verdict":request.verdict,"normalized_verdict":accepted.normalized_verdict,
                  "summary":request.summary,"recommendations":list(accepted.recommendations),
                  "carryover":list(accepted.carryover),"coverage_digest":accepted.coverage_digest,
                  "coverage":request.coverage,"observation":observation}
            body=encode({"review_id":history.id,"revision_id":history.current_revision,
                "snapshot_digest":history.snapshot.digest,"series_scope":config.series_scope,
                "request_digest":digest,"data":data})
            event=Event(event_id,len(history.events)+1,history.current_revision,"submit_review",body,
                        hashlib.sha256(body).hexdigest(),view.store_version+1)
            receipt=encode({"event_id":event_id,"operation":"submit_review","review_id":history.id,
                "revision_id":history.current_revision,"snapshot_digest":history.snapshot.digest,
                "series_scope":config.series_scope,"request_digest":digest,"store_version":view.store_version+1,
                "observation":observation,"result":{"accepted":True,"normalized_verdict":accepted.normalized_verdict,
                    "accepted_round":history.verdict_count+1,
                    "new_finding_ids":[finding["record"]["id"] for finding in accepted.recommendations]}})
            return Mutation(event,None,receipt)
        async def checkpoint():
            pass
        with Store.open(config,store.repo_binding,policy=store.policy) as reviewer:
            return await reviewer.mutate(config.series_scope,config.participant,"submit_review",request.key,digest,
                                         request.expected_version,build,checkpoint)
    return append


class Flow:
    def __init__(self,config,writer,author,reviewer):
        self.config,self.writer,self.author,self.reviewer=config,writer,author,reviewer

    @staticmethod
    def bound(response):
        return {key:response[key] for key in ("review_id","revision_id","snapshot_digest")}

    async def open(self,key="initial"):
        status=await self.author.review_status({})
        assert status["ok"],status
        return await self.author.open_review({"key":key,"expected_version":status["store_version"]})

    async def listing(self,response,view,*,limit=100):
        items=[]
        cursor=None
        while True:
            result=await self.reviewer.read_review({**self.bound(response),"view":view,"limit":limit,"cursor":cursor})
            assert result["ok"],result
            page=result["result"]
            items.extend(page["items"])
            if page["complete"]:
                assert page["next_cursor"] is None
                return items
            assert page["items"] and page["next_cursor"]!=cursor
            cursor=page["next_cursor"]

    async def verdict_request(self,*,recommendations=None,disposition="addressed",**overrides):
        status=await self.reviewer.review_status({})
        assert status["ok"],status
        rows=await self.listing(status,"manifest")
        value={**self.bound(status),"key":f"round_{status['store_version']}",
               "expected_version":status["store_version"],"verdict":"approve","summary":"reviewed pinned bytes",
               "recommendations":recommendations or [],"coverage_digest":status["snapshot_digest"],
               "coverage":[row["change"]["change_id"] for row in rows],
               "carryover":[{"id":f["id"],"digest":f["digest"],"status":disposition,
                             "reason":"checked against pinned source"} for f in status["result"]["finding_rollups"]]}
        value.update(overrides)
        return value

    async def submit(self,**options):
        return await self.reviewer.submit_review(await self.verdict_request(**options))

    async def evidence_request(self,**overrides):
        status=await self.author.review_status({})
        assert status["ok"],status
        value={**self.bound(status),"key":f"evidence_{status['store_version']}","expected_version":status["store_version"],
               "origin":"agent_report","command":"pytest","runtime":"Python","exit_status":0,
               "content":{"kind":"inline","data_b64":"cHJvb2Y="}}
        value.update(overrides)
        return value

    async def commit_fix(self):
        parent=self.author.store.read_series().snapshot.header["source_oid"]
        head=self.writer.commit({b"file":(0o100644,b"fixed")},parents=[parent])
        self.writer.set_ref(self.config.source_ref,head)
        return await self.open("fixed_revision")


@pytest.fixture
def flow(cfg,git_fixture):
    from contextlib import ExitStack
    from dataclasses import replace
    from gauntlet_review.collaborative.core import ReviewCore
    from gauntlet_review.collaborative.contracts import Policy
    from gauntlet_review.collaborative.source import GitSource
    from gauntlet_review.collaborative.store import Store
    git_fixture.pair({}, {b"file":(0o100644,b"one")})
    with ExitStack() as resources:
        cores=[]
        for config in (cfg,replace(cfg,participant="peer",role="reviewer")):
            source=resources.enter_context(GitSource(config))
            store=resources.enter_context(Store.open(config,source.repo_binding))
            core=ReviewCore(config,source,store,Policy())
            resources.callback(core.close)
            cores.append(core)
        yield Flow(cfg,git_fixture,*cores)
