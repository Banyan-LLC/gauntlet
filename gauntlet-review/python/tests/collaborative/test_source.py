"""Object-level fixtures avoid host filesystem path normalization entirely."""
import base64
from dataclasses import asdict, replace
import hashlib
import os
from pathlib import Path
import zlib

import pytest

from gauntlet_review.collaborative.contracts import CoreError, Policy


def source_type():
    from gauntlet_review.collaborative.source import GitSource
    return GitSource


def test_pinned_bytes_ignore_dirty_and_untracked_worktree(git_fixture, cfg):
    git_fixture.pair({b"file":(0o100644,b"old\0")}, {b"file":(0o100755,b"new\0")})
    with source_type()(cfg) as source:
        snapshot=source.capture(Policy())
        git_fixture.write_worktree_file("file", b"different")
        git_fixture.write_worktree_file("untracked", b"not reviewed")
        change=snapshot.changes[0]
        page=source.read_blob(change.new_oid, 0, 64, change.new_digest)
        assert page.data == b"new\0" and page.eof and page.total == 4
        assert change.old_mode == 0o100644 and change.new_mode == 0o100755


def test_raw_paths_binary_empty_modes_symlinks_and_gitlinks_remain_distinct(git_fixture, cfg):
    old={b"deleted":(0o100644,b"removed"), b"mode":(0o100644,b"same")}
    new={b"A":(0o100644,b"upper"), b"a":(0o100644,b"lower"),
         b"\xc3\xa9":(0o100644,b"NFC"), b"e\xcc\x81":(0o100644,b"NFD"),
         b"\xff":(0o100644,b"\0\xff"), b"empty":(0o100644,b""),
         b"mode":(0o100755,b"same"), b"link":(0o120000,b"/etc/passwd"),
         b"sub":(0o160000,b"e"*40)}
    git_fixture.pair(old,new)
    with source_type()(cfg) as source:
        snap=source.capture(Policy())
        rows=list(source.manifest_rows(snap))
        paths=[base64.b64decode(r.change.new_path_b64 or r.change.old_path_b64) for r in rows]
        assert paths == sorted(set(old)|set(new))
        assert len({r.change.change_id for r in rows}) == 10
        handles=[]
        for row,path in zip(rows,paths):
            for side, files, handle in (("base",old,row.old_artifact),("head",new,row.new_artifact)):
                if path not in files or files[path][0] == 0o160000:
                    assert handle is None
                    continue
                assert handle.side == side
                result=source.read_blob(handle.oid,0,65536,handle.sha256)
                assert result.data == files[path][1] and result.eof
                handles.append(handle.artifact_id)
        assert len(handles) == len(set(handles))
        assert not (cfg.repo_path / "A").exists()
        assert not (cfg.repo_path / "link").exists()
        inventory=list(source.source_entries(snap))
        assert {base64.b64decode(e.raw_path_b64) for e in inventory} == set(new)
        assert next(e for e in inventory if base64.b64decode(e.raw_path_b64)==b"sub").artifact_id is None


def test_exact_pages_validate_whole_blob_on_every_read(git_fixture,cfg):
    body=b"a"*65536+b"b"*17
    git_fixture.pair({}, {b"page":(0o100644,body)})
    with source_type()(cfg) as source:
        change=source.capture(Policy()).changes[0]
        first=source.read_blob(change.new_oid,0,65536,change.new_digest)
        last=source.read_blob(change.new_oid,65536,65536,change.new_digest)
        assert first.data == b"a"*65536 and not first.eof
        assert last.data == b"b"*17 and last.eof
        assert first.digest == last.digest == hashlib.sha256(body).hexdigest()
        loose=cfg.repo_path / ".git" / "objects" / change.new_oid[:2] / change.new_oid[2:]
        loose.write_bytes(zlib.compress(b"blob 65553\0"+b"a"*65536+b"c"*17))
        with pytest.raises(CoreError) as error:
            source.read_blob(change.new_oid,0,10,change.new_digest)
        assert error.value.code == "DIGEST_MISMATCH"


def test_missing_pinned_blob_never_falls_back_to_worktree(git_fixture,cfg):
    git_fixture.pair({}, {b"file":(0o100644,b"pinned")})
    with source_type()(cfg) as source:
        snap=source.capture(Policy())
        change=snap.changes[0]
        (cfg.repo_path/".git"/"objects"/change.new_oid[:2]/change.new_oid[2:]).unlink()
        git_fixture.write_worktree_file("file",b"substitute")
        for call in (lambda:source.read_blob(change.new_oid,0,64,change.new_digest),
                     lambda:source.check_snapshot(snap)):
            with pytest.raises(CoreError) as error:
                call()
            assert error.value.code == "MISSING_OBJECT"


def test_new_commit_with_identical_tree_is_observed_as_drift(git_fixture,cfg):
    _, head=git_fixture.pair({}, {b"file":(0o100644,b"one")})
    with source_type()(cfg) as source:
        snap=source.capture(Policy())
        replacement=git_fixture.commit({b"file":(0o100644,b"one")},parents=[head])
        git_fixture.set_ref(cfg.source_ref,replacement)
        observation=source.check_snapshot(snap)
        assert observation.source_oid == replacement
        assert observation.source_oid != snap.header["source_oid"]


def test_capture_ref_movement_is_refused(git_fixture,cfg,monkeypatch):
    _, head=git_fixture.pair({}, {b"file":(0o100644,b"one")})
    replacement=git_fixture.commit({b"file":(0o100644,b"two")},parents=[head])
    with source_type()(cfg) as source:
        original=source._blob
        def moving(*args,**kwargs):
            result=original(*args,**kwargs)
            git_fixture.set_ref(cfg.source_ref,replacement)
            return result
        monkeypatch.setattr(source,"_blob",moving)
        with pytest.raises(CoreError) as error:
            source.capture(Policy())
        assert error.value.code == "STALE"


def test_disconnected_target_and_noncommit_refs_are_refused(git_fixture,cfg):
    base=git_fixture.commit({})
    head=git_fixture.commit({b"a":(0o100644,b"a")})
    git_fixture.set_ref(cfg.target_ref,base)
    git_fixture.set_ref(cfg.source_ref,head)
    with source_type()(cfg) as source:
        with pytest.raises(CoreError) as error:
            source.capture(Policy())
        assert error.value.code == "NEEDS_SYNC"
        from dulwich.objects import Blob
        blob=Blob.from_string(b"not a commit")
        git_fixture.repo.object_store.add_object(blob)
        git_fixture.repo.refs[cfg.target_ref]=blob.id
        with pytest.raises(CoreError) as error:
            source.observe()
        assert error.value.code == "UNSUPPORTED_REPOSITORY"


@pytest.mark.parametrize("policy,old,new", [
    (replace(Policy(),changed_paths=1),{}, {b"a":(0o100644,b"a"),b"b":(0o100644,b"b")}),
    (replace(Policy(),changed_bytes=3),{b"a":(0o100644,b"aa")},{b"a":(0o100755,b"aa")}),
    (replace(Policy(),graph_commits=1),{}, {b"a":(0o100644,b"a")}),
    (replace(Policy(),tree_entries=1),{}, {b"a":(0o100644,b"a"),b"b":(0o100644,b"b")}),
    (Policy(),{}, {b"x"*4097:(0o100644,b"a")}),
    (Policy(),{}, {b"a":(0o100644,b"x"*(4*1024*1024+1))}),
])
def test_complete_capture_refuses_each_source_quota_before_admission(git_fixture,cfg,policy,old,new):
    git_fixture.pair(old,new)
    with source_type()(cfg) as source:
        with pytest.raises(CoreError) as error:
            source.capture(policy)
        assert error.value.code == "LIMIT_EXCEEDED"


@pytest.mark.parametrize("kind", ["shallow","promisor","extension","sha256"])
def test_unsupported_repository_states_fail_closed(git_fixture,cfg,kind):
    base,_=git_fixture.pair({}, {b"file":(0o100644,b"file")})
    if kind == "shallow":
        (cfg.repo_path/".git"/"shallow").write_text(base+"\n",encoding="ascii")
    else:
        config=git_fixture.repo.get_config()
        if kind == "promisor":
            config.set((b"remote",b"origin"),b"promisor",b"true")
        else:
            config.set((b"core",),b"repositoryformatversion",b"1")
            config.set((b"extensions",),b"objectformat" if kind == "sha256" else b"unknown",b"sha256" if kind == "sha256" else b"true")
        config.write_to_path()
    with pytest.raises(CoreError) as error:
        with source_type()(cfg) as source:
            source.capture(Policy())
    assert error.value.code == "UNSUPPORTED_REPOSITORY"


def test_linked_worktree_has_same_binding_and_snapshot(git_fixture,cfg,tmp_path):
    _,head=git_fixture.pair({}, {b"file":(0o100644,b"file")})
    from dulwich.worktree import add_worktree
    linked=tmp_path/"linked"
    add_worktree(git_fixture.repo,str(linked),commit=head.encode("ascii"),detach=True).close()
    with source_type()(cfg) as first, source_type()(replace(cfg,repo_path=linked)) as second:
        assert first.repo_binding == second.repo_binding == os.path.normcase(str((cfg.repo_path/".git").resolve()))
        original=first.capture(Policy())
        assert second.capture(Policy()) == original
        assert list(first.manifest_rows(original)) == list(second.manifest_rows(original))


def test_relative_configuration_fails_before_dulwich_open(cfg,monkeypatch):
    from gauntlet_review.collaborative import source
    def forbidden(*args,**kwargs):
        raise AssertionError("opened before validation")
    monkeypatch.setattr(source,"Repo",forbidden)
    with pytest.raises(CoreError) as error:
        source.GitSource(replace(cfg,repo_path=Path("relative")))
    assert error.value.code == "CONFIGURATION_ERROR"


def test_repository_handles_close_after_capture_exception(git_fixture,cfg,monkeypatch):
    from gauntlet_review.collaborative import source as module
    real=module.Repo
    opened=[]
    class TrackedRepo:
        def __init__(self,*args,**kwargs):
            self.repo=real(*args,**kwargs)
            self.closed=False
            opened.append(self)
        def __enter__(self):
            return self.repo
        def __exit__(self,*args):
            self.repo.close()
            self.closed=True
    git_fixture.pair({}, {b"a":(0o100644,b"a"),b"b":(0o100644,b"b")})
    monkeypatch.setattr(module,"Repo",TrackedRepo)
    with module.GitSource(cfg) as source:
        with pytest.raises(CoreError):
            source.capture(replace(Policy(),changed_paths=1))
    assert len(opened) >= 2 and all(repo.closed for repo in opened)
    with pytest.raises(CoreError) as error:
        source.observe()
    assert error.value.code == "CONFIGURATION_ERROR"


def test_read_page_bounds_and_expected_hash_are_refused(git_fixture,cfg):
    git_fixture.pair({}, {b"file":(0o100644,b"one")})
    with source_type()(cfg) as source:
        change=source.capture(Policy()).changes[0]
        for offset,length in ((True,1),(0,True),(-1,1),(4,1),(0,65537),(0,0)):
            with pytest.raises(CoreError) as error:
                source.read_blob(change.new_oid,offset,length,change.new_digest)
            assert error.value.code == "INVALID_ARGUMENT"
        with pytest.raises(CoreError) as error:
            source.read_blob(change.new_oid,0,1,"f"*64)
        assert error.value.code == "DIGEST_MISMATCH"


def test_source_operations_do_not_write_repository_metadata(git_fixture,cfg):
    git_fixture.pair({}, {b"file":(0o100644,b"one")})
    def metadata():
        return {str(path.relative_to(cfg.repo_path)):hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (cfg.repo_path/".git").rglob("*") if path.is_file()}
    before=metadata()
    with source_type()(cfg) as source:
        snap=source.capture(Policy())
        source.check_snapshot(snap)
        list(source.source_entries(snap))
        list(source.manifest_rows(snap))
        change=snap.changes[0]
        source.read_blob(change.new_oid,0,1,change.new_digest)
    assert metadata() == before
