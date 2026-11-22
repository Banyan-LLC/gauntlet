import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

import pytest

from gauntlet_review import launch

GIT = shutil.which("git")
pytestmark = pytest.mark.skipif(GIT is None, reason="git is needed to build the fixture repositories")


def git(cwd, *args):
    subprocess.run([GIT, "-C", str(cwd), *args], check=True, capture_output=True,
                   env={**os.environ, "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                        "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"})


@pytest.fixture
def checkout(tmp_path):
    """A repository on branch feature/x with origin's default branch main, cloned from a bare origin."""
    origin = tmp_path / "Owner" / "Repo.git"
    origin.mkdir(parents=True)
    git(origin, "init", "--bare", "-q", "-b", "main")
    seed = tmp_path / "seed"
    git(tmp_path, "clone", "-q", str(origin), str(seed))
    (seed / "a.txt").write_text("one\n")
    git(seed, "add", "a.txt")
    git(seed, "commit", "-q", "-m", "one")
    git(seed, "push", "-q", "origin", "HEAD:main")
    work = tmp_path / "work"
    git(tmp_path, "clone", "-q", str(origin), str(work))
    git(work, "checkout", "-q", "-b", "feature/x")
    git(work, "remote", "set-url", "origin", "git@github.com:Owner/Repo.git")
    return work


def test_derives_the_tuple_from_the_working_folder(checkout, tmp_path):
    (checkout / "sub").mkdir()
    t = launch.derive(checkout / "sub", tmp_path / "state")
    assert t.repo == checkout.resolve()
    assert t.repository_id == "owner-repo"
    assert t.source_ref == b"refs/heads/feature/x"
    assert t.target_ref == b"refs/remotes/origin/main"
    assert t.state_dir.parent == tmp_path / "state"                  # never resolved: the core checks this path
    assert re.fullmatch(r"owner-repo--feature-x-[0-9a-f]{12}", t.state_dir.name)


def test_a_linked_worktree_is_its_own_checkout_with_its_own_branch(checkout, tmp_path):
    other = tmp_path / "other"
    git(checkout, "worktree", "add", "-q", "-b", "feature/y", str(other))
    t = launch.derive(other, tmp_path / "state")
    assert t.repo == other.resolve()
    assert t.source_ref == b"refs/heads/feature/y"
    assert t.target_ref == b"refs/remotes/origin/main"
    assert t.state_dir != launch.derive(checkout, tmp_path / "state").state_dir


def test_each_checkout_and_ref_pair_gets_its_own_state_directory(checkout, tmp_path):
    first = launch.derive(checkout, tmp_path / "state").state_dir
    git(checkout, "checkout", "-q", "-b", "feature-x")                  # the same slug as feature/x
    assert launch.derive(checkout, tmp_path / "state").state_dir != first


def test_origin_head_names_the_target_when_it_exists(checkout, tmp_path):
    git(checkout, "update-ref", "refs/remotes/origin/trunk", "HEAD")
    git(checkout, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
    assert launch.derive(checkout, tmp_path / "state").target_ref == b"refs/remotes/origin/trunk"


@pytest.mark.parametrize("url, expected", [
    ("https://github.com/Banyan-LLC/RetroSeq.git", "banyan-llc-retroseq"),
    ("git@github.com:Banyan-LLC/c64-adventure-creator.git", "banyan-llc-c64-adventure-creator"),
    ("ssh://git@example.com/group/Some.Project/", "group-some-project"),
])
def test_repository_id_comes_from_origin_url(checkout, tmp_path, url, expected):
    git(checkout, "remote", "set-url", "origin", url)
    assert launch.derive(checkout, tmp_path / "state").repository_id == expected


def test_repository_id_falls_back_to_the_folder_name_and_stays_valid(tmp_path):
    assert launch._repository_id("", Path("My Project!")) == "my-project"
    assert launch._repository_id("", Path("x" * 100)) == "x" * 64
    assert launch._repository_id("", Path("!!!")) == "repository"


def test_refuses_a_folder_outside_any_checkout(tmp_path):
    with pytest.raises(launch.LaunchRefused) as refused:
        launch.derive(tmp_path, tmp_path / "state")
    assert refused.value.code == "NOT_A_GIT_CHECKOUT"


def test_refuses_a_detached_head(checkout, tmp_path):
    git(checkout, "checkout", "-q", "--detach")
    with pytest.raises(launch.LaunchRefused) as refused:
        launch.derive(checkout, tmp_path / "state")
    assert refused.value.code == "DETACHED_HEAD"


def test_refuses_without_an_origin_default_branch(checkout, tmp_path):
    git(checkout, "remote", "remove", "origin")
    with pytest.raises(launch.LaunchRefused) as refused:
        launch.derive(checkout, tmp_path / "state")
    assert refused.value.code == "NO_TARGET_REF"


def test_refuses_a_state_root_inside_the_checkout(checkout):
    with pytest.raises(launch.LaunchRefused) as refused:
        launch.derive(checkout, checkout / ".state")
    assert refused.value.code == "STATE_INSIDE_REPOSITORY"


def test_creates_private_state_directories_and_keeps_existing_ones(tmp_path):
    state = tmp_path / "root" / "one"
    launch.ensure_private_dir(state)
    assert state.is_dir()
    if os.name == "nt":
        acl = subprocess.run(["icacls", str(state)], capture_output=True, text=True, check=True).stdout
        assert "(I)" not in acl                                          # no inherited entries
        assert os.environ["USERNAME"].lower() in acl.lower()
    else:
        for path in (state, state.parent):
            assert stat.S_IMODE(path.stat().st_mode) == 0o700
    launch.ensure_private_dir(state)                                     # already there: unchanged, no error


def test_refuses_a_redirected_state_component(tmp_path):
    real = tmp_path / "real"
    real.mkdir()
    link = tmp_path / "link"
    try:
        link.symlink_to(real, target_is_directory=True)
    except OSError:
        pytest.skip("symbolic links are not available to this account")
    with pytest.raises(launch.LaunchRefused) as refused:
        launch.ensure_private_dir(link / "one")
    assert refused.value.code == "REDIRECTED_STATE_COMPONENT"


def capture_session(monkeypatch, real_servers=False):
    """Replaces session.serve (and, unless real_servers, both factories) so main returns without stdio."""
    from gauntlet_review import session
    seen = {}
    if not real_servers:
        def core(resolver):
            seen.update(role="core", resolver=resolver)
            return "core-server"

        def peer(resolver, timeout_seconds, extended_timeout, model=None):
            seen.update(role="peer", resolver=resolver, timeout=timeout_seconds, extended=extended_timeout)
            return "peer-server"
        monkeypatch.setattr(session, "create_core_server", core)
        monkeypatch.setattr(session, "create_peer_server", peer)

    def serve(server):
        seen["served"] = server
        return 0
    monkeypatch.setattr(session, "serve", serve)
    return seen


def session_lines(root, role):
    return [line for line in (root / "launch.log").read_text().splitlines() if f" {role} session cwd=" in line]


@pytest.mark.parametrize("role", ["core", "peer"])
def test_main_starts_a_real_session_server_without_deriving_anything(checkout, tmp_path, monkeypatch, role):
    pytest.importorskip("gauntlet_review.codex_bridge.server" if role == "peer" else "mcp")
    seen = capture_session(monkeypatch, real_servers=True)
    monkeypatch.chdir(checkout)
    root = tmp_path / "state"
    assert launch.main([role, "--state-root", str(root), "--timeout-seconds", "900"]) == 0
    assert seen["served"].name == ("gauntlet-collaborative" if role == "core" else "gauntlet-codex")
    assert sorted(p.name for p in root.iterdir()) == ["launch.log"]          # no store until a call binds one
    assert len(session_lines(root, role)) == 1 and "extended_timeout" not in (root / "launch.log").read_text()


@pytest.mark.parametrize("role", ["core", "peer"])
def test_main_hands_the_state_root_and_role_to_the_session_server(checkout, tmp_path, monkeypatch, role):
    seen = capture_session(monkeypatch)
    monkeypatch.chdir(checkout)
    root = tmp_path / "state"
    assert launch.main([role, "--state-root", str(root), "--timeout-seconds", "900"]) == 0
    assert seen["role"] == role and seen["served"] == f"{role}-server"
    assert seen["resolver"].role == role and seen["resolver"].state_root == root
    if role == "peer":
        assert (seen["timeout"], seen["extended"]) == (900, False)


@pytest.mark.parametrize("timeout", ["1800", "5400", "7200"])
def test_main_forwards_the_extended_timeout_override_and_logs_it(checkout, tmp_path, monkeypatch, timeout):
    seen = capture_session(monkeypatch)
    monkeypatch.chdir(checkout)
    root = tmp_path / "state"
    assert launch.main(["peer", "--state-root", str(root), "--timeout-seconds", timeout,
                        "--allow-extended-timeout"]) == 0
    assert (seen["timeout"], seen["extended"]) == (int(timeout), True)
    line = (root / "launch.log").read_text().splitlines()[-1]
    assert line.split(" ", 1)[1].startswith("peer session cwd=")
    assert line.endswith(f" timeout_seconds={timeout} extended_timeout=on max_seconds=7200")


def test_the_launcher_forwards_the_adapters_own_flag():
    engine = pytest.importorskip("gauntlet_review.codex_bridge.engine")
    assert launch.EXTENDED_TIMEOUT_FLAG == engine.EXTENDED_TIMEOUT_FLAG == "--allow-extended-timeout"


def test_main_ignores_the_override_for_the_core(checkout, tmp_path, monkeypatch):
    seen = capture_session(monkeypatch)
    monkeypatch.chdir(checkout)
    root = tmp_path / "state"
    assert launch.main(["core", "--state-root", str(root), "--allow-extended-timeout"]) == 0
    assert seen["role"] == "core"
    assert "extended_timeout" not in (root / "launch.log").read_text()


@pytest.mark.parametrize("args, expected, hint", [
    (["--timeout-seconds", "5400"],
     '{"code":"TIMEOUT_OUT_OF_RANGE","operation":"launch","accepted":{"min":10,"max":1800},'
     '"opt_in":{"flag":"--allow-extended-timeout","max":7200}}',
     "--timeout-seconds 5400 is outside 10-1800; add --allow-extended-timeout to accept up to 7200"),
    (["--timeout-seconds", "1801"],
     '{"code":"TIMEOUT_OUT_OF_RANGE","operation":"launch","accepted":{"min":10,"max":1800},'
     '"opt_in":{"flag":"--allow-extended-timeout","max":7200}}',
     "--timeout-seconds 1801 is outside 10-1800; add --allow-extended-timeout to accept up to 7200"),
    (["--timeout-seconds", "7201", "--allow-extended-timeout"],
     '{"code":"TIMEOUT_OUT_OF_RANGE","operation":"launch","accepted":{"min":10,"max":7200}}',
     "--timeout-seconds 7201 is outside 10-7200 (--allow-extended-timeout is on)"),
    (["--timeout-seconds", "9"],
     '{"code":"TIMEOUT_OUT_OF_RANGE","operation":"launch","accepted":{"min":10,"max":1800}}',
     "--timeout-seconds 9 is outside 10-1800"),
])
def test_main_refuses_an_out_of_range_timeout_before_the_hand_off(checkout, tmp_path, monkeypatch, capsys,
                                                                 args, expected, hint):
    seen = capture_session(monkeypatch)
    monkeypatch.chdir(checkout)
    root = tmp_path / "state"
    root.mkdir()
    assert launch.main(["peer", "--state-root", str(root), *args]) == 2
    assert capsys.readouterr().err.strip() == expected
    assert "served" not in seen
    assert f"refused TIMEOUT_OUT_OF_RANGE: {hint} (cwd=" in (root / "launch.log").read_text()
    assert list(root.iterdir()) == [root / "launch.log"]                     # no state directory was created


def test_main_starts_from_a_folder_outside_any_checkout(tmp_path, monkeypatch, capsys):
    seen = capture_session(monkeypatch)
    root = tmp_path / "state"
    root.mkdir()
    monkeypatch.chdir(tmp_path)
    assert launch.main(["core", "--state-root", str(root)]) == 0
    assert seen["served"] == "core-server" and capsys.readouterr().err == ""
    assert len(session_lines(root, "core")) == 1
    assert launch.main(["core", "--state-root", "relative"]) == 2
    assert launch.main(["bogus", "--state-root", str(root)]) == 2


def test_main_creates_a_missing_state_root_and_logs_its_session_line(tmp_path, monkeypatch):
    seen = capture_session(monkeypatch)
    plain = tmp_path / "plain"
    plain.mkdir()
    monkeypatch.chdir(plain)
    root = tmp_path / "fresh-state"
    assert launch.main(["peer", "--state-root", str(root)]) == 0                # no tool call follows
    assert seen["served"] == "peer-server"
    if os.name == "nt":
        acl = subprocess.run(["icacls", str(root)], capture_output=True, text=True, check=True).stdout
        assert "(I)" not in acl and os.environ["USERNAME"].lower() in acl.lower()
    else:
        assert stat.S_IMODE(root.stat().st_mode) == 0o700
    assert sorted(p.name for p in root.iterdir()) == ["launch.log"]
    assert len(session_lines(root, "peer")) == 1


def test_main_refuses_a_state_root_whose_parent_is_missing(tmp_path, monkeypatch, capsys):
    capture_session(monkeypatch)
    monkeypatch.chdir(tmp_path)
    root = tmp_path / "absent" / "state"
    assert launch.main(["core", "--state-root", str(root)]) == 2
    assert capsys.readouterr().err.strip() == '{"code":"STATE_UNAVAILABLE","operation":"launch"}'
    assert not (tmp_path / "absent").exists()


def redirect(link, target):
    """A junction on Windows (no privilege needed), a symbolic link elsewhere."""
    if os.name == "nt":
        import _winapi
        _winapi.CreateJunction(str(target), str(link))
    else:
        link.symlink_to(target, target_is_directory=True)


def no_paths_or_traceback(err, *paths):
    assert "Traceback" not in err
    for path in paths:
        assert str(path) not in err and str(path).replace("\\", "\\\\") not in err


@pytest.mark.parametrize("shape", ["root", "ancestor"])
def test_main_refuses_a_redirected_state_root_before_writing_anything(checkout, tmp_path, monkeypatch, capsys, shape):
    capture_session(monkeypatch)
    target = tmp_path / "elsewhere"
    target.mkdir()
    link = tmp_path / "link"
    redirect(link, target)
    root = link if shape == "root" else link / "state"                   # an existing redirected root, or under one
    monkeypatch.chdir(checkout)
    assert launch.main(["core", "--state-root", str(root)]) == 2
    err = capsys.readouterr().err
    assert err.strip() == '{"code":"REDIRECTED_STATE_COMPONENT","operation":"launch"}'
    assert list(target.iterdir()) == []                                   # no state and no log through the redirect
    with pytest.raises(launch.LaunchRefused) as refused:
        launch.derive(checkout, root)
    assert refused.value.code == "REDIRECTED_STATE_COMPONENT"


def test_derive_hands_over_the_unresolved_state_path(checkout, tmp_path):
    root = tmp_path / "state"
    assert launch.derive(checkout, root).state_dir.parent == root


@pytest.mark.parametrize("error, code", [
    (PermissionError(13, "Access is denied", r"C:\secret\state"), "STATE_UNAVAILABLE"),
    (subprocess.TimeoutExpired(["icacls", r"C:\secret\state"], 30), "STATE_NOT_PRIVATE"),
    (FileNotFoundError(2, "icacls not found", "icacls"), "STATE_UNAVAILABLE"),
])
def test_main_contains_setup_failures_with_fixed_codes(checkout, tmp_path, monkeypatch, capsys, error, code):
    seen = capture_session(monkeypatch)

    def fail(path):
        raise error
    monkeypatch.setattr(launch, "_restrict", fail)
    monkeypatch.chdir(checkout)
    root = tmp_path / "state"                                              # absent: main creates and restricts it
    assert launch.main(["core", "--state-root", str(root)]) == 2
    err = capsys.readouterr().err
    assert err.strip() == '{"code":"%s","operation":"launch"}' % code
    no_paths_or_traceback(err, root, checkout, r"C:\secret\state")
    assert not root.exists() and "served" not in seen                     # the half-made root was removed


def test_main_contains_an_unexpected_failure_with_a_correlation_id(checkout, tmp_path, monkeypatch, capsys):
    from gauntlet_review import session
    capture_session(monkeypatch)

    def boom(role, state_root):
        raise RuntimeError(f"unexpected near {state_root}")
    monkeypatch.setattr(session, "Resolver", boom)
    monkeypatch.chdir(checkout)
    root = tmp_path / "state"
    root.mkdir()
    assert launch.main(["peer", "--state-root", str(root)]) == 2
    err = capsys.readouterr().err
    body = __import__("json").loads(err)
    assert set(body) == {"code", "operation", "correlation_id"} and body["code"] == "INTERNAL_ERROR"
    assert re.fullmatch(r"[0-9a-f]{32}", body["correlation_id"])
    no_paths_or_traceback(err, root)
    assert body["correlation_id"] in (root / "launch.log").read_text()


def test_a_failed_cleanup_never_replaces_the_original_error(checkout, tmp_path, monkeypatch, capsys):
    capture_session(monkeypatch)

    def refuse(path):
        raise launch.LaunchRefused("STATE_NOT_PRIVATE", "icacls refused")
    real_rmdir = Path.rmdir

    def stuck(self):
        raise OSError(32, "in use")
    monkeypatch.setattr(launch, "_restrict", refuse)
    monkeypatch.setattr(Path, "rmdir", stuck)
    monkeypatch.chdir(checkout)
    root = tmp_path / "state"                                              # created, refused, and stuck in place
    try:
        assert launch.main(["core", "--state-root", str(root)]) == 2
    finally:
        monkeypatch.setattr(Path, "rmdir", real_rmdir)
    assert capsys.readouterr().err.strip() == '{"code":"STATE_NOT_PRIVATE","operation":"launch"}'
    log = (root / "launch.log").read_text()
    assert "icacls refused" in log and "cleanup failed" in log


def test_main_refuses_missing_pins_for_the_session_server(checkout, tmp_path, monkeypatch, capsys):
    from gauntlet_review.collaborative import server as core_server
    capture_session(monkeypatch, real_servers=True)

    def missing():
        raise core_server.StartupError("UNSUPPORTED_EXTRA")
    monkeypatch.setattr(core_server, "_require_extra", missing)
    monkeypatch.chdir(checkout)
    root = tmp_path / "state"
    assert launch.main(["core", "--state-root", str(root)]) == 2
    assert capsys.readouterr().err.strip() == '{"code":"UNSUPPORTED_EXTRA","operation":"launch"}'
    assert "refused UNSUPPORTED_EXTRA" in (root / "launch.log").read_text()


def test_check_passes_with_the_pinned_extras(capsys):
    pytest.importorskip("gauntlet_review.codex_bridge.server")
    from gauntlet_review.codex_bridge import server as peer_server
    try:
        peer_server._require_extra()
    except Exception:
        pytest.skip("this environment does not hold the [codex] extra")
    assert launch.main(["check"]) == 0
    assert capsys.readouterr().err == ""


@pytest.mark.parametrize("version, code", [(None, "MISSING_EXTRA"), ("0.0.0", "UNSUPPORTED_EXTRA")])
def test_check_reports_missing_or_unsupported_pins(monkeypatch, capsys, version, code):
    from importlib import metadata

    def fake(name):
        if version is None:
            raise metadata.PackageNotFoundError(name)
        return version
    monkeypatch.setattr(metadata, "version", fake)
    assert launch.main(["check"]) == 2
    assert capsys.readouterr().err.strip() == '{"code":"%s","operation":"launch"}' % code
