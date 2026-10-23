"""Keep legacy session creation faithful while retaining matrix custody."""
import os
from pathlib import Path
import subprocess

import pytest


@pytest.fixture(autouse=True)
def legacy_session_custody(monkeypatch):
    if os.name=="posix" and os.environ.get("GAUNTLET_TEST_TRACK_LEGACY_SESSIONS")=="1":
        support=Path(__file__).resolve().parents[3]/"tests/support"
        monkeypatch.syspath_prepend(str(support))
        from collaborative_legacy import track_sessions
        monkeypatch.setattr(subprocess,"Popen",track_sessions(subprocess.Popen))
