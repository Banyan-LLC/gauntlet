"""The per-call binding resolver behind the session servers (gauntlet_review.session)."""
import os
import stat
import subprocess
from pathlib import Path

import pytest

from gauntlet_review import launch, session


def private(path):
    if os.name == "nt":
        acl = subprocess.run(["icacls", str(path)], capture_output=True, text=True, check=True).stdout
        return "(I)" not in acl and os.environ["USERNAME"].lower() in acl.lower()
    return stat.S_IMODE(path.stat().st_mode) == 0o700


def test_resolves_a_checkout_exactly_as_the_launcher_derives_it(make_checkout, tmp_path):
    work = make_checkout()
    root = tmp_path / "state"
    bound = session.Resolver("core", root).resolve(str(work))
    assert bound == launch.derive(work, root)
    assert bound.state_dir.is_dir() and private(bound.state_dir)
    assert session.public(bound) == {"checkout": str(work.resolve()), "repository_id": "owner-repo",
                                     "source_ref": "refs/heads/feature/x", "target_ref": "refs/remotes/origin/main"}


def test_a_branch_switch_takes_effect_on_the_next_call(make_checkout, run_git, tmp_path):
    work = make_checkout()
    resolver = session.Resolver("core", tmp_path / "state")
    first = resolver.resolve(str(work))
    run_git(work, "checkout", "-q", "-b", "feature/y")
    second = resolver.resolve(str(work))
    assert second.source_ref == b"refs/heads/feature/y"
    assert second.state_dir != first.state_dir and first.state_dir.is_dir()


def test_a_linked_worktree_and_its_subfolders_bind_the_worktree(make_checkout, run_git, tmp_path):
    work = make_checkout()
    other = tmp_path / "other"
    run_git(work, "worktree", "add", "-q", "-b", "feature/z", str(other))
    (other / "deep").mkdir()
    resolver = session.Resolver("core", tmp_path / "state")
    bound = resolver.resolve(str(other))
    assert bound.repo == other.resolve() and bound.source_ref == b"refs/heads/feature/z"
    assert resolver.resolve(str(other / "deep")) == bound
    assert resolver.resolve(str(work)).source_ref == b"refs/heads/feature/x"


def test_a_folder_outside_any_checkout_is_a_retryable_refusal(tmp_path):
    outside = tmp_path / "plain"
    outside.mkdir()
    for folder in (outside, tmp_path / "missing"):
        with pytest.raises(session.BindingError) as refused:
            session.Resolver("core", tmp_path / "state").resolve(str(folder))
        assert refused.value.code == "NOT_A_GIT_CHECKOUT" and refused.value.retryable
        assert "checkout" in refused.value.hint and str(folder) not in refused.value.hint


def test_a_detached_head_is_refused_until_a_branch_is_checked_out(make_checkout, run_git, tmp_path):
    work = make_checkout()
    run_git(work, "checkout", "-q", "--detach")
    resolver = session.Resolver("core", tmp_path / "state")
    with pytest.raises(session.BindingError) as refused:
        resolver.resolve(str(work))
    assert refused.value.code == "DETACHED_HEAD" and refused.value.retryable
    assert "no reconnect" in refused.value.hint
    run_git(work, "switch", "-q", "-c", "fix/z")
    assert resolver.resolve(str(work)).source_ref == b"refs/heads/fix/z"


def test_a_missing_origin_default_branch_is_retryable(make_checkout, run_git, tmp_path):
    work = make_checkout()
    run_git(work, "remote", "remove", "origin")
    with pytest.raises(session.BindingError) as refused:
        session.Resolver("core", tmp_path / "state").resolve(str(work))
    assert refused.value.code == "NO_TARGET_REF" and refused.value.retryable


@pytest.mark.parametrize("value", [session.MISSING, None])
def test_checkout_is_required(tmp_path, value):
    with pytest.raises(session.BindingError) as refused:
        session.Resolver("core", tmp_path / "state").resolve(value)
    assert (refused.value.code, refused.value.reason) == ("INVALID_ARGUMENT", "checkout_required")
    assert "current working folder" in refused.value.hint and not refused.value.retryable


WINDOWS_REFUSED = ["\\\\server\\share", "//server/share", "\\/server/share", "/\\server\\share", "\\\\?\\C:\\x",
                   "\\\\.\\pipe\\x", "\\??\\C:\\x", "\\x", "C:x", "relative\\x", "relative/x", "", "/x"]
WINDOWS_ACCEPTED = ["C:\\x", "C:/x", "c:\\x\\y", "Z:\\"]
POSIX_REFUSED = ["//x/y", "relative/x", "/a\\b", "", "C:\\x", "\\x"]
POSIX_ACCEPTED = ["/x/y", "/"]


@pytest.mark.parametrize("windows, value, expected",
                         [(True, v, False) for v in WINDOWS_REFUSED] + [(True, v, True) for v in WINDOWS_ACCEPTED]
                         + [(False, v, False) for v in POSIX_REFUSED] + [(False, v, True) for v in POSIX_ACCEPTED])
def test_only_local_absolute_paths_in_native_form_are_accepted(windows, value, expected):
    assert session.local_absolute(value, windows=windows) is expected


NATIVE_UNC = "\\/server/share" if os.name == "nt" else "//server/share"


@pytest.mark.parametrize("value", ["relative/path", NATIVE_UNC, "C:/a\x01b" if os.name == "nt" else "/a\x01b",
                                   "/x\x7f" if os.name != "nt" else "C:\\x\x7f", ("C:\\" if os.name == "nt" else "/") + "x" * 4097,
                                   7, True, b"/x", ["C:\\x"]])
def test_an_invalid_checkout_is_refused_before_touching_anything(tmp_path, value):
    root = tmp_path / "state"
    with pytest.raises(session.BindingError) as refused:
        session.Resolver("core", root).resolve(value)
    assert (refused.value.code, refused.value.reason) == ("INVALID_ARGUMENT", "invalid_checkout")
    assert not root.exists()


def test_each_binding_is_logged_once_and_refusals_each_time(make_checkout, tmp_path):
    work = make_checkout()
    root = tmp_path / "state"
    resolver = session.Resolver("peer", root)
    for _ in range(3):
        resolver.resolve(str(work))
    for _ in range(2):
        with pytest.raises(session.BindingError):
            resolver.resolve(str(tmp_path / "missing"))
    lines = (root / "launch.log").read_text(encoding="utf-8").splitlines()
    binds = [line for line in lines if " peer bind " in line]
    assert len(binds) == 1 and "source=refs/heads/feature/x" in binds[0] and f"checkout={work.resolve()}" in binds[0]
    assert sum(" peer refused NOT_A_GIT_CHECKOUT" in line for line in lines) == 2


@pytest.mark.parametrize("error, code", [
    (PermissionError(13, "Access is denied", r"C:\secret\state"), "STATE_UNAVAILABLE"),
    (subprocess.TimeoutExpired(["icacls", r"C:\secret\state"], 30), "STATE_NOT_PRIVATE"),
    (launch.LaunchRefused("STATE_NOT_PRIVATE", "icacls refused"), "STATE_NOT_PRIVATE"),
])
def test_a_state_directory_that_cannot_be_made_private_is_removed_and_refused(make_checkout, tmp_path, monkeypatch,
                                                                              error, code):
    work = make_checkout()
    root = tmp_path / "state"
    root.mkdir()

    def fail(path):
        raise error
    monkeypatch.setattr(launch, "_restrict", fail)
    with pytest.raises(session.BindingError) as refused:
        session.Resolver("core", root).resolve(str(work))
    assert refused.value.code == code and not refused.value.retryable
    assert sorted(p.name for p in root.iterdir()) == ["launch.log"]        # the half-made directory was removed
    assert f"core refused {code}" in (root / "launch.log").read_text(encoding="utf-8")


def test_an_unexpected_failure_has_a_correlation_id_in_the_log(make_checkout, tmp_path, monkeypatch):
    work = make_checkout()
    root = tmp_path / "state"
    root.mkdir()

    def boom(folder, state_root):
        raise RuntimeError("unexpected")
    monkeypatch.setattr(launch, "derive", boom)
    with pytest.raises(session.BindingError) as refused:
        session.Resolver("core", root).resolve(str(work))
    assert refused.value.code == "INTERNAL_ERROR" and len(refused.value.correlation_id) == 32
    assert refused.value.correlation_id in (root / "launch.log").read_text(encoding="utf-8")
