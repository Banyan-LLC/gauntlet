"""The operator's commands to list Codex models and switch the peer's model and effort."""
import json
import os
import shutil
import subprocess

import pytest

from gauntlet_review import launch, model_cli, peer_model
from gauntlet_review.codex_bridge.catalog import Catalog, CatalogModel

GIT = shutil.which("git")
EFFORTS = ("low", "medium", "high", "xhigh", "max", "ultra")
CATALOG = Catalog((
    CatalogModel("gpt-6.1-sol", "GPT-6.1-Sol", False, False, "low", EFFORTS),
    CatalogModel("gpt-6-luna", "GPT-6-Luna", True, False, "medium", EFFORTS[:-1]),
    CatalogModel("codex-auto-review", "Codex Auto Review", False, True, "low", ("low",)),
), True)
BUILT_IN = {"model": "gpt-6.1-sol", "model_source": "built_in", "effort": "xhigh", "effort_source": "built_in"}


def git(cwd, *args):
    subprocess.run([GIT, "-C", str(cwd), *args], check=True, capture_output=True,
                   env={**os.environ, "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                        "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"})


@pytest.fixture
def checkout(tmp_path):
    """A repository on branch feature/x whose origin is Owner/Repo (copied from test_launch.py)."""
    if GIT is None:
        pytest.skip("git is needed to build the fixture repositories")
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


@pytest.fixture
def catalog(monkeypatch):
    calls = []

    def fetch():
        calls.append(1)
        if isinstance(fetch.result, BaseException):
            raise fetch.result
        return fetch.result

    fetch.result = CATALOG
    fetch.calls = calls
    monkeypatch.setattr(model_cli, "fetch_catalog", fetch)
    monkeypatch.setattr(model_cli, "_require_extra", lambda: None)
    return fetch


def run(capsys, *argv):
    code = model_cli.main(list(argv))
    out, err = capsys.readouterr()
    return code, out, err


def run_json(capsys, *argv):
    code, out, err = run(capsys, *argv, "--json")
    assert code == 0, err
    return json.loads(out)


def refused(capsys, code, *argv):
    status, out, err = run(capsys, *argv)
    assert status == 2 and err.startswith(f"{code}: "), err
    return err


def settings_bytes(root):
    path = root / peer_model.SETTINGS_NAME
    return path.read_bytes() if path.exists() else None


def log_text(root):
    path = root / launch.LOG_NAME
    return path.read_text() if path.exists() else ""


def test_models_lists_visible_models_and_the_selection(tmp_path, capsys, catalog, monkeypatch):
    root = tmp_path / "state"
    listed = run_json(capsys, "models", "--state-root", str(root))
    assert listed["selection"] == BUILT_IN
    assert [m["model"] for m in listed["models"]] == ["gpt-6.1-sol", "gpt-6-luna"]
    assert listed["models"][1] == {"model": "gpt-6-luna", "display_name": "GPT-6-Luna", "catalog_default": True,
                                   "hidden": False, "default_effort": "medium", "efforts": list(EFFORTS[:-1])}
    every = run_json(capsys, "models", "--state-root", str(root), "--all")
    assert [m["model"] for m in every["models"]][-1] == "codex-auto-review"
    code, out, _ = run(capsys, "models", "--state-root", str(root))
    assert code == 0 and "gpt-6.1-sol" in out and "gpt-6-luna" in out and "codex-auto-review" not in out

    def missing():
        from gauntlet_review.collaborative.server import StartupError
        raise StartupError("MISSING_EXTRA")

    monkeypatch.setattr(model_cli, "_require_extra", missing)
    refused(capsys, "MISSING_EXTRA", "models", "--state-root", str(root))


def test_show_on_a_fresh_install_creates_nothing(tmp_path, capsys, catalog):
    root = tmp_path / "state"
    assert run_json(capsys, "models", "--state-root", str(root))["selection"] == BUILT_IN
    shown = run_json(capsys, "model", "--state-root", str(root))
    assert shown == {"scope": "global", "selection": BUILT_IN, "repositories": {}}
    assert run_json(capsys, "model", "--state-root", str(root), "--repository-id", "owner-repo") == {
        "scope": "repository", "repository_id": "owner-repo", "settings": {}, "selection": BUILT_IN}
    code, out, _ = run(capsys, "model", "--state-root", str(root))
    assert code == 0 and "gpt-6.1-sol" in out
    assert not root.exists()


def test_set_model_only_effort_only_and_both(tmp_path, capsys, catalog):
    root = tmp_path / "state"
    changed = run_json(capsys, "model", "--state-root", str(root), "gpt-6-luna")
    assert changed["scope"] == "global" and changed["repository_id"] is None and changed["warnings"] == []
    assert changed["settings"] == {"model": "gpt-6-luna"}
    assert changed["selection"] == {"model": "gpt-6-luna", "model_source": "global", "effort": "xhigh",
                                    "effort_source": "built_in"}
    run_json(capsys, "model", "--state-root", str(root), "--effort", "high", "--repository-id", "owner-repo")
    run_json(capsys, "model", "--state-root", str(root), "gpt-6.1-sol", "--effort", "max",
             "--repository-id", "other-repo")
    assert json.loads(settings_bytes(root)) == {"version": 1, "default": {"model": "gpt-6-luna"}, "repositories": {
        "other-repo": {"effort": "max", "model": "gpt-6.1-sol"}, "owner-repo": {"effort": "high"}}}
    lines = [line.split(" ", 1)[1] for line in log_text(root).splitlines()]
    assert lines == ["peer-model set scope=global model=gpt-6-luna",
                     "peer-model set scope=repository:owner-repo effort=high",
                     "peer-model set scope=repository:other-repo model=gpt-6.1-sol effort=max"]
    code, out, _ = run(capsys, "model", "--state-root", str(root), "--effort", "low")
    assert code == 0 and "next peer turn" in out


def test_display_names_and_capitals_are_accepted(tmp_path, capsys, catalog):
    root = tmp_path / "state"
    changed = run_json(capsys, "model", "--state-root", str(root), "GPT-6-LUNA", "--effort", "HIGH")
    assert changed["settings"] == {"model": "gpt-6-luna", "effort": "high"}


def test_unknown_model_and_unsupported_effort_write_nothing(tmp_path, capsys, catalog):
    root = tmp_path / "state"
    peer_model.save(root, peer_model.with_fields(peer_model.EMPTY, None, effort="ultra"))
    before = settings_bytes(root)
    refused(capsys, "UNKNOWN_MODEL", "model", "--state-root", str(root), "gpt-7")
    err = refused(capsys, "EFFORT_NOT_SUPPORTED", "model", "--state-root", str(root), "gpt-6-luna",
                  "--effort", "ultra")
    assert "low medium high xhigh max" in err
    # The repository would inherit the global effort ultra, which luna lacks.
    err = refused(capsys, "EFFORT_NOT_SUPPORTED", "model", "--state-root", str(root), "gpt-6-luna",
                  "--repository-id", "owner-repo")
    assert "--effort" in err
    assert settings_bytes(root) == before and log_text(root) == ""


def test_a_global_change_warns_about_broken_repositories(tmp_path, capsys, catalog):
    root = tmp_path / "state"
    peer_model.save(root, peer_model.with_fields(peer_model.EMPTY, "r", effort="ultra"))
    changed = run_json(capsys, "model", "--state-root", str(root), "gpt-6-luna", "--effort", "high")
    assert changed["warnings"] == [{"repository_id": "r", "model": "gpt-6-luna", "effort": "ultra",
                                    "code": "EFFORT_NOT_SUPPORTED"}]
    assert json.loads(settings_bytes(root))["default"] == {"effort": "high", "model": "gpt-6-luna"}
    code, out, _ = run(capsys, "model", "--state-root", str(root), "--effort", "medium")
    assert code == 0 and "warning" in out.lower() and " r " in out.replace(":", " ")


def test_catalog_unavailable_writes_nothing(tmp_path, capsys, catalog):
    root = tmp_path / "state"
    catalog.result = RuntimeError("not signed in")
    err = refused(capsys, "CATALOG_UNAVAILABLE", "model", "--state-root", str(root), "gpt-6-luna")
    assert "signed in" in err
    refused(capsys, "CATALOG_UNAVAILABLE", "models", "--state-root", str(root))
    catalog.result = Catalog(CATALOG.models[1:], False)
    refused(capsys, "CATALOG_UNAVAILABLE", "model", "--state-root", str(root), "gpt-6.1-sol")
    assert not root.exists()


def test_reset_needs_no_catalog(tmp_path, capsys, catalog):
    root = tmp_path / "state"
    peer_model.save(root, peer_model.Settings({"model": "gpt-6-luna", "effort": "high"},
                                              {"r": {"model": "gpt-6-luna", "effort": "low"}}))
    catalog.result = RuntimeError("must not be asked")
    assert run_json(capsys, "model", "--state-root", str(root), "--reset", "effort",
                    "--repository-id", "r")["settings"] == {"model": "gpt-6-luna"}
    assert run_json(capsys, "model", "--state-root", str(root), "--reset", "model",
                    "--repository-id", "r")["settings"] == {}
    reset = run_json(capsys, "model", "--state-root", str(root), "--reset")
    assert reset["selection"] == BUILT_IN
    assert json.loads(settings_bytes(root)) == {"version": 1}
    assert catalog.calls == []
    lines = [line.split(" ", 1)[1] for line in log_text(root).splitlines()]
    assert lines == ["peer-model reset scope=repository:r fields=effort",
                     "peer-model reset scope=repository:r fields=model",
                     "peer-model reset scope=global fields=model,effort"]


def test_repo_derives_the_launchers_id(tmp_path, capsys, catalog, checkout):
    root = tmp_path / "state"
    (checkout / "sub").mkdir()
    worktree = tmp_path / "linked"
    git(checkout, "worktree", "add", "-q", "-b", "feature/y", str(worktree))
    for folder in (checkout, checkout / "sub", worktree):
        assert run_json(capsys, "model", "--state-root", str(root), "--effort", "high",
                        "--repo", str(folder))["repository_id"] == "owner-repo"
    assert model_cli.repository_id_of(worktree) == launch.derive(worktree, root).repository_id
    outside = tmp_path / "outside"
    outside.mkdir()
    refused(capsys, "NOT_A_GIT_CHECKOUT", "model", "--state-root", str(root), "--effort", "high",
            "--repo", str(outside))


def test_repository_ids_must_be_slugs(tmp_path, capsys, catalog):
    root = tmp_path / "state"
    for bad in ("Owner-Repo", "owner_repo", "owner/repo"):
        err = refused(capsys, "CONFIGURATION_ERROR", "model", "--state-root", str(root), "--effort", "high",
                      "--repository-id", bad)
        assert "--repo" in err
    assert run_json(capsys, "model", "--state-root", str(root), "--effort", "high",
                    "--repository-id", "owner-repo")["repository_id"] == "owner-repo"


@pytest.mark.parametrize("extra", [
    ["--effort", "high", "--repo", "REPO", "--repository-id", "owner-repo"],
    ["--reset", "--effort", "high"],
    ["gpt-6-luna", "--reset"],
    ["--effort", "very-high"],
    ["--reset", "everything"],
    ["--unknown"],
], ids=["repo-and-id", "reset-and-effort", "reset-and-model", "bad-effort", "bad-reset", "unknown"])
def test_argument_refusals(tmp_path, capsys, catalog, extra):
    root = tmp_path / "state"
    extra = [str(tmp_path) if item == "REPO" else item for item in extra]
    refused(capsys, "CONFIGURATION_ERROR", "model", "--state-root", str(root), *extra)
    refused(capsys, "CONFIGURATION_ERROR", "model", "--state-root", "relative", "--effort", "high")
    refused(capsys, "CONFIGURATION_ERROR", "models")
    assert not root.exists()


def test_invalid_settings_are_reported(tmp_path, capsys, catalog):
    root = tmp_path / "state"
    root.mkdir()
    (root / peer_model.SETTINGS_NAME).write_text("{broken")
    refused(capsys, "MODEL_SETTINGS_INVALID", "model", "--state-root", str(root))
    refused(capsys, "MODEL_SETTINGS_INVALID", "model", "--state-root", str(root), "gpt-6-luna")
    refused(capsys, "MODEL_SETTINGS_INVALID", "models", "--state-root", str(root))
    assert (root / peer_model.SETTINGS_NAME).read_text() == "{broken"


def _near_limit(gap):
    """Settings whose written form is exactly SETTINGS_BYTES - gap, with repository 'target' on gpt-6-luna."""
    entries = {f"{i:03d}-" + "a" * 60: {"model": "m", "effort": "x" * 32} for i in range(255)}
    entries["target"] = {"model": "gpt-6-luna"}
    keys = sorted(key for key in entries if key != "target")
    while (deficit := peer_model.SETTINGS_BYTES - gap -
           len(peer_model.encode_document(peer_model.Settings({}, entries)))) > 0:
        key = next(k for k in reversed(keys) if len(entries[k]["model"]) < 128)
        entries[key]["model"] += "m" * min(128 - len(entries[key]["model"]), deficit)
    settings = peer_model.Settings({}, entries)
    assert len(peer_model.encode_document(settings)) == peer_model.SETTINGS_BYTES - gap
    return settings


def test_a_change_beyond_the_limits_writes_nothing(tmp_path, capsys, catalog):
    root = tmp_path / "state"
    peer_model.save(root, peer_model.Settings({}, {f"r{i}": {"model": "gpt-6-luna"} for i in range(256)}))
    before = settings_bytes(root)
    err = refused(capsys, "CONFIGURATION_ERROR", "model", "--state-root", str(root), "gpt-6.1-sol",
                  "--repository-id", "r256")
    assert "256" in err
    assert settings_bytes(root) == before
    # "gpt-6.1-sol" is one byte longer than "gpt-6-luna": the written form would cross 64 KiB by one byte.
    peer_model.save(root, _near_limit(0))
    before = settings_bytes(root)
    err = refused(capsys, "CONFIGURATION_ERROR", "model", "--state-root", str(root), "gpt-6.1-sol",
                  "--repository-id", "target")
    assert str(peer_model.SETTINGS_BYTES) in err
    assert settings_bytes(root) == before and log_text(root) == ""


def test_a_failed_save_reports_and_logs_nothing(tmp_path, capsys, catalog, monkeypatch):
    root = tmp_path / "state"
    root.mkdir()

    def broken(root, settings):
        raise OSError("disk full")

    monkeypatch.setattr(peer_model, "save", broken)
    refused(capsys, "STATE_UNAVAILABLE", "model", "--state-root", str(root), "gpt-6-luna")
    refused(capsys, "STATE_UNAVAILABLE", "model", "--state-root", str(root), "--reset")
    assert log_text(root) == ""


def test_launch_dispatches_the_subcommands(monkeypatch, capsys):
    seen = []
    monkeypatch.setattr(model_cli, "main", lambda argv: seen.append(argv) or 0)
    assert launch.main(["models", "--state-root", "x"]) == 0
    assert launch.main(["model", "--state-root", "x", "--reset"]) == 0
    assert seen == [["models", "--state-root", "x"], ["model", "--state-root", "x", "--reset"]]
    assert launch.main(["check"]) == 0



DISPLAYED = Catalog((
    CatalogModel("gpt-6.1-terra", "GPT-6.1 Terra", True, False, "low", EFFORTS),
    CatalogModel("gpt-6.1-sol", "GPT-6.1-Sol", False, False, "low", EFFORTS),
    CatalogModel("twin-a", "Twin", False, False, "low", EFFORTS),
    CatalogModel("twin-b", "Twin", False, False, "low", EFFORTS),
), True)


def test_codex_display_names_resolve_to_the_slug(tmp_path, capsys, catalog):
    # R4-F2: the names Codex displays, spaces and capitals included, select the model; the slug is stored.
    root = tmp_path / "state"
    catalog.result = DISPLAYED
    changed = run_json(capsys, "model", "--state-root", str(root), "GPT-6.1 Terra", "--effort", "HIGH")
    assert changed["settings"] == {"model": "gpt-6.1-terra", "effort": "high"}
    assert run_json(capsys, "model", "--state-root", str(root), "gpt-6.1   TERRA")["settings"]["model"] == "gpt-6.1-terra"
    before = settings_bytes(root)
    err = refused(capsys, "CONFIGURATION_ERROR", "model", "--state-root", str(root), "twin")
    assert "twin-a" in err and "twin-b" in err
    refused(capsys, "UNKNOWN_MODEL", "model", "--state-root", str(root), "GPT 7 Imaginary")
    assert settings_bytes(root) == before
    code, out, _ = run(capsys, "models", "--state-root", str(root))
    assert code == 0 and "GPT-6.1 Terra" in out and "GPT-6.1-Sol" in out


@pytest.mark.parametrize("failure", ["deep", "root"])
def test_unreadable_settings_are_refused_without_writing(tmp_path, capsys, catalog, monkeypatch, failure):
    # R4-F1: exit 2 with MODEL_SETTINGS_INVALID, never a traceback, and nothing written or logged.
    root = tmp_path / "state"
    root.mkdir()
    if failure == "deep":
        (root / peer_model.SETTINGS_NAME).write_text("[" * 30000 + "]" * 30000)
    else:
        peer_model.save(root, peer_model.with_fields(peer_model.EMPTY, None, effort="high"))

        def unreadable(path):
            raise PermissionError("access denied")

        monkeypatch.setattr(launch, "check_unredirected", unreadable)
    before = settings_bytes(root)
    for argv in (("model",), ("model", "gpt-6-luna"), ("models",)):
        refused(capsys, "MODEL_SETTINGS_INVALID", *argv, "--state-root", str(root))
    assert settings_bytes(root) == before and log_text(root) == ""
