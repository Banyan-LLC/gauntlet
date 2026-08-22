import hashlib
import json
import os
from pathlib import Path

import pytest

from gauntlet_review.broker import BrokerError, stage_credential

AGENTS = b"# account AGENTS.md\nreview presentation rules\n"
AGENTS_SHA = hashlib.sha256(AGENTS).hexdigest()


def _codex_home(tmp_path) -> str:
    home = tmp_path / "codex-home"
    home.mkdir()
    (home / "AGENTS.md").write_bytes(AGENTS)
    return str(home)


def _provider(expires_at):
    return lambda: {"json": json.dumps({"tokens": {"access_token": "AT"}}), "expires_at": expires_at}


def test_stages_auth_and_agents_when_hash_matches(tmp_path):
    home = _codex_home(tmp_path)
    stg = tmp_path / "stg"
    stage_credential(codex_home=home, staging_dir=str(stg), agents_md_sha256=AGENTS_SHA,
                     min_lifetime_sec=1800, token_provider=_provider(10_000), now=0.0)
    assert (stg / "auth.json").is_file() and (stg / "AGENTS.md").read_bytes() == AGENTS
    if os.name == "posix":  # mode bits are POSIX-specific; the offline suite also runs on Windows
        assert (stg.stat().st_mode & 0o777) == 0o700
        assert ((stg / "auth.json").stat().st_mode & 0o777) == 0o600
        assert ((stg / "AGENTS.md").stat().st_mode & 0o777) == 0o600


def test_write_failure_after_makedirs_rolls_back_staging_dir(tmp_path):
    # A non-str token json makes the auth.json write raise after the staging dir exists.
    # The broker must fail closed AND leave no half-staged (credential-bearing) dir behind.
    home = _codex_home(tmp_path)
    stg = tmp_path / "stg"
    bad_provider = lambda: {"json": 123, "expires_at": 10_000}  # 123 -> fh.write raises TypeError
    with pytest.raises(BrokerError):
        stage_credential(codex_home=home, staging_dir=str(stg), agents_md_sha256=AGENTS_SHA,
                         min_lifetime_sec=1800, token_provider=bad_provider, now=0.0)
    assert not stg.exists()


def test_agents_hash_mismatch_fails_closed(tmp_path):
    home = _codex_home(tmp_path)
    stage = tmp_path / "stg"
    with pytest.raises(BrokerError):
        stage_credential(codex_home=home, staging_dir=str(stage), agents_md_sha256="0" * 64,
                         min_lifetime_sec=1800, token_provider=_provider(10_000), now=0.0)


def test_insufficient_token_lifetime_fails_closed(tmp_path):
    home = _codex_home(tmp_path)
    stage = tmp_path / "stg"
    with pytest.raises(BrokerError):
        stage_credential(codex_home=home, staging_dir=str(stage), agents_md_sha256=AGENTS_SHA,
                         min_lifetime_sec=1800, token_provider=_provider(100), now=0.0)  # 100s < 1800s


def test_symlinked_agents_md_rejected(tmp_path):
    home = Path(_codex_home(tmp_path))
    (home / "AGENTS.md").unlink()
    outside = tmp_path / "evil.md"
    outside.write_bytes(b"evil")
    try:
        (home / "AGENTS.md").symlink_to(outside)
    except (OSError, NotImplementedError):
        pytest.skip("symlinks not supported")
    with pytest.raises((BrokerError, OSError)):
        stage_credential(codex_home=str(home), staging_dir=str(tmp_path / "stg"),
                         agents_md_sha256=AGENTS_SHA, min_lifetime_sec=1800,
                         token_provider=_provider(10_000), now=0.0)


def test_symlinked_agents_md_with_matching_hash_still_rejected(tmp_path):
    # No-follow must hold INDEPENDENT of the hash check: a symlink whose target carries the
    # approved bytes must still be rejected (POSIX: O_NOFOLLOW; Windows: islink fail-closed).
    home = Path(_codex_home(tmp_path))
    (home / "AGENTS.md").unlink()
    real = tmp_path / "real-agents.md"
    real.write_bytes(AGENTS)  # target has the EXACT approved bytes -> hash would match
    try:
        (home / "AGENTS.md").symlink_to(real)
    except (OSError, NotImplementedError):
        pytest.skip("symlinks not supported")
    with pytest.raises((BrokerError, OSError)):
        stage_credential(codex_home=str(home), staging_dir=str(tmp_path / "stg2"),
                         agents_md_sha256=AGENTS_SHA, min_lifetime_sec=1800,
                         token_provider=_provider(10_000), now=0.0)
