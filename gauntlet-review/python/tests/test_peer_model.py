"""The operator's peer model settings: built-in default, per-field inheritance, safe reads and writes."""
import json
import os
import sys
import threading

import pytest

from gauntlet_review import peer_model
from gauntlet_review.peer_model import EMPTY, Selection, Settings, SettingsError

EXAMPLE = {"version": 1, "default": {"effort": "max"}, "repositories": {"r": {"model": "gpt-6-sol"}}}


def write(root, data):
    root.mkdir(parents=True, exist_ok=True)
    path = root / peer_model.SETTINGS_NAME
    path.write_bytes(data if isinstance(data, bytes) else json.dumps(data).encode())
    return path


def temporaries(root):
    return sorted(p.name for p in root.iterdir() if p.name.endswith(".tmp"))


def test_missing_root_or_file_is_the_built_in_default(tmp_path):
    builtin = Selection("gpt-6.1-sol", "xhigh", "built_in", "built_in")
    assert peer_model.selection_for(tmp_path / "absent", "r") == builtin
    assert peer_model.selection_for(tmp_path, "r") == builtin
    assert not (tmp_path / "absent").exists()
    assert builtin.public() == {"model": "gpt-6.1-sol", "model_source": "built_in",
                                "effort": "xhigh", "effort_source": "built_in"}


def test_fields_inherit_one_at_a_time(tmp_path):
    write(tmp_path, EXAMPLE)
    assert peer_model.selection_for(tmp_path, "r") == Selection("gpt-6-sol", "max", "repository", "global")
    for other in ("other", None):
        assert peer_model.selection_for(tmp_path, other) == Selection("gpt-6.1-sol", "max", "built_in", "global")


def test_fixed_selection_sources():
    assert peer_model.fixed(None, None) == Selection("gpt-6.1-sol", "xhigh", "built_in", "built_in")
    assert peer_model.fixed("m", None) == Selection("m", "xhigh", "operator", "built_in")
    assert peer_model.fixed(None, "low") == Selection("gpt-6.1-sol", "low", "built_in", "operator")


def _many(count, model="m"):
    return json.dumps({"version": 1, "repositories": {f"r{i}": {"model": model} for i in range(count)}}).encode()


@pytest.mark.parametrize("data", [
    b"not json",
    b"[]",
    b'{"version":2}',
    b'{"version":true}',
    b'{"default":{"model":"m"}}',
    b'{"version":1,"other":{}}',
    b'{"version":1,"default":{"model":"m","x":"y"}}',
    b'{"version":1,"version":1}',
    b'{"version":1,"default":{"model":"a","model":"b"}}',
    b'{"version":1,"repositories":{"r":{"effort":"low"},"r":{"effort":"high"}}}',
    b'{"version":1,"default":{}}',
    b'{"version":1,"repositories":{"r":{}}}',
    b'{"version":1,"default":{"model":"bad model"}}',
    b'{"version":1,"default":{"effort":"High"}}',
    b'{"version":1,"default":{"model":7}}',
    b'{"version":1,"repositories":{"a/b":{"model":"m"}}}',
    b'{"version":1,"repositories":[]}',
    _many(257),
    b'{"version":1,"default":{"model":NaN}}',
    b'{"version":1}' + b" " * peer_model.SETTINGS_BYTES,
    b"\xff\xfe",
], ids=["not-json", "array", "version-2", "version-true", "no-version", "unknown-top", "unknown-entry",
        "duplicate-top", "duplicate-entry", "duplicate-repository", "empty-default", "empty-repository",
        "bad-model", "bad-effort", "model-not-string", "bad-repository-id", "repositories-array",
        "too-many-repositories", "nan", "oversize", "invalid-utf8"])
def test_invalid_files_are_refused(tmp_path, data):
    write(tmp_path, data)
    with pytest.raises(SettingsError) as refused:
        peer_model.load(tmp_path)
    assert refused.value.code == "MODEL_SETTINGS_INVALID"


def test_a_bom_is_accepted(tmp_path):
    write(tmp_path, b"\xef\xbb\xbf" + json.dumps(EXAMPLE).encode())
    assert peer_model.selection_for(tmp_path, "r").model == "gpt-6-sol"


def test_the_open_refuses_a_link(tmp_path):
    target = tmp_path / "real.json"
    target.write_text(json.dumps(EXAMPLE))
    try:
        os.symlink(target, tmp_path / peer_model.SETTINGS_NAME)
    except (OSError, NotImplementedError):
        pytest.skip("this account cannot create symbolic links")
    with pytest.raises(SettingsError):
        peer_model.load(tmp_path)


@pytest.mark.skipif(os.name != "nt", reason="Windows handle attributes")
@pytest.mark.parametrize("attribute", [0x400, 0x10], ids=["reparse-point", "directory"])
def test_a_reparse_point_seen_on_the_handle_is_refused(tmp_path, monkeypatch, attribute):
    write(tmp_path, EXAMPLE)
    monkeypatch.setattr(peer_model, "_handle_attributes", lambda handle: attribute)
    with pytest.raises(SettingsError):
        peer_model.load(tmp_path)


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="POSIX FIFOs")
def test_a_fifo_is_refused_without_blocking(tmp_path):
    os.mkfifo(tmp_path / peer_model.SETTINGS_NAME)
    outcome = []

    def attempt():
        try:
            peer_model.load(tmp_path)
            outcome.append("loaded")
        except SettingsError:
            outcome.append("refused")

    worker = threading.Thread(target=attempt, daemon=True)
    worker.start()
    worker.join(1)
    assert outcome == ["refused"]


def test_a_redirected_state_root_is_refused(tmp_path):
    real = tmp_path / "real"
    write(real, EXAMPLE)
    link = tmp_path / "link"
    if os.name == "nt":
        import _winapi
        _winapi.CreateJunction(str(real), str(link))
    else:
        os.symlink(real, link, target_is_directory=True)
    with pytest.raises(SettingsError):
        peer_model.load(link)
    other = tmp_path / "other"
    (other / peer_model.SETTINGS_NAME).mkdir(parents=True)
    with pytest.raises(SettingsError):
        peer_model.load(other)


def test_save_round_trips_privately(tmp_path):
    root = tmp_path / "state"
    settings = peer_model.with_fields(peer_model.with_fields(EMPTY, None, effort="max"), "r", model="gpt-6-sol")
    peer_model.save(root, settings)
    assert peer_model.load(root) == settings
    assert (root / peer_model.SETTINGS_NAME).read_bytes() == peer_model.encode_document(settings)
    assert peer_model.encode_document(settings).endswith(b"}\n") and b"\r" not in peer_model.encode_document(settings)
    assert json.loads(peer_model.encode_document(settings)) == peer_model.to_document(settings) == EXAMPLE
    assert temporaries(root) == []
    if os.name != "nt":
        assert (root / peer_model.SETTINGS_NAME).stat().st_mode & 0o777 == 0o600


def _repositories(count, model_length):
    # 64-character IDs, the longest effort the syntax allows and the given model length.
    return Settings({}, {f"{i:03d}-" + "a" * 60: {"model": "m" * model_length, "effort": "x" * 32}
                         for i in range(count)})


def test_save_refuses_candidates_beyond_the_limits(tmp_path):
    root = tmp_path / "state"
    peer_model.save(root, peer_model.with_fields(EMPTY, None, model="gpt-6-sol"))
    original = (root / peer_model.SETTINGS_NAME).read_bytes()
    expanded = _repositories(256, 128)
    compact = json.dumps(peer_model.to_document(expanded), separators=(",", ":")).encode()
    assert len(compact) <= peer_model.SETTINGS_BYTES < len(peer_model.encode_document(expanded))
    too_many = Settings({}, {f"r{i}": {"model": "m"} for i in range(257)})
    for candidate in (too_many, expanded):
        with pytest.raises(SettingsError) as refused:
            peer_model.save(root, candidate)
        assert refused.value.code == "CONFIGURATION_ERROR"
        assert (root / peer_model.SETTINGS_NAME).read_bytes() == original
        assert temporaries(root) == []
    # Grow one model until the written form is exactly at the limit: it is written and loads.
    fitting = _repositories(256, 1)
    entries = {key: dict(value) for key, value in fitting.repositories.items()}
    keys = sorted(entries)
    while (deficit := peer_model.SETTINGS_BYTES - len(peer_model.encode_document(Settings({}, entries)))) > 0:
        key = next(k for k in reversed(keys) if len(entries[k]["model"]) < 128)
        entries[key]["model"] += "m" * min(128 - len(entries[key]["model"]), deficit)
    exact = Settings({}, entries)
    assert len(peer_model.encode_document(exact)) == peer_model.SETTINGS_BYTES
    peer_model.save(root, exact)
    assert peer_model.load(root) == exact


def test_save_retries_transient_replace_failures(tmp_path, monkeypatch):
    root = tmp_path / "state"
    calls = []
    real = peer_model._replace

    def flaky(source, target):
        calls.append(source)
        if len(calls) < 3:
            raise PermissionError("in use")
        real(source, target)

    monkeypatch.setattr(peer_model, "_replace", flaky)
    monkeypatch.setattr(peer_model, "RETRY_DELAY", 0)
    settings = peer_model.with_fields(EMPTY, None, model="gpt-6-sol")
    peer_model.save(root, settings)
    assert len(calls) == 3 and peer_model.load(root) == settings and temporaries(root) == []


def test_save_gives_up_after_bounded_retries(tmp_path, monkeypatch):
    root = tmp_path / "state"
    peer_model.save(root, peer_model.with_fields(EMPTY, None, model="gpt-6-sol"))
    original = (root / peer_model.SETTINGS_NAME).read_bytes()
    calls = []

    def busy(source, target):
        calls.append(source)
        raise PermissionError("in use")

    monkeypatch.setattr(peer_model, "_replace", busy)
    monkeypatch.setattr(peer_model, "RETRY_DELAY", 0)
    with pytest.raises(PermissionError):
        peer_model.save(root, peer_model.with_fields(EMPTY, None, model="gpt-6-luna"))
    assert len(calls) == 5
    assert (root / peer_model.SETTINGS_NAME).read_bytes() == original and temporaries(root) == []


def test_a_failed_temporary_write_keeps_the_original(tmp_path, monkeypatch):
    root = tmp_path / "state"
    peer_model.save(root, peer_model.with_fields(EMPTY, None, model="gpt-6-sol"))
    original = (root / peer_model.SETTINGS_NAME).read_bytes()
    replaced = []
    monkeypatch.setattr(peer_model, "_replace", lambda source, target: replaced.append(source))

    def partial(path, data):
        with open(path, "xb") as handle:
            handle.write(data[:10])
        raise OSError("disk full")

    monkeypatch.setattr(peer_model, "_write_new", partial)
    with pytest.raises(OSError):
        peer_model.save(root, peer_model.with_fields(EMPTY, None, model="gpt-6-luna"))
    assert replaced == []
    assert (root / peer_model.SETTINGS_NAME).read_bytes() == original and temporaries(root) == []


def test_with_and_without_fields():
    one = peer_model.with_fields(EMPTY, "r", effort="high")
    assert peer_model.to_document(one) == {"version": 1, "repositories": {"r": {"effort": "high"}}}
    assert peer_model.without_fields(one, "r", ("effort",)) == EMPTY
    both = peer_model.with_fields(EMPTY, None, model="m", effort="low")
    assert peer_model.to_document(peer_model.without_fields(both, None, ("model",))) == {
        "version": 1, "default": {"effort": "low"}}
    assert peer_model.without_fields(EMPTY, "absent", ("model", "effort")) == EMPTY
    assert peer_model.scope_name(None) == "global" and peer_model.scope_name("r") == "repository:r"
