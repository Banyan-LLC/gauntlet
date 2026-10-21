import json
import os
from pathlib import Path
import uuid

import pytest

from gauntlet_review.collaborative.contracts import CoreError
from gauntlet_review.collaborative.store import Store


@pytest.mark.parametrize("suffix",["","-journal","-wal","-shm"])
def test_redirected_database_or_sidecar_is_refused_without_touching_target(cfg,tmp_path,suffix):
    target=tmp_path/"preserved-target"
    target.write_bytes(b"preserve exact bytes")
    link=cfg.state_dir/(Store.FILENAME+suffix)
    try:
        link.symlink_to(target)
    except OSError as error:
        if os.name!="nt" or os.environ.get("GAUNTLET_REQUIRE_FILE_SYMLINK")=="1":
            raise
        report={"capability":"file_symlink","status":"unsupported_fixture",
                "platform":os.name,"winerror":getattr(error,"winerror",None),
                "required_ci":"Windows runner must enable file-symlink privilege"}
        archive=Path(json.loads(os.environ["GAUNTLET_TEST_OWNER"])["receipts"])
        (archive/("security-fixture-unsupported-"+uuid.uuid4().hex+".json")).write_text(json.dumps(report))
        pytest.skip("unsupported local file-symlink privilege; required capable-runner coverage pending")
    with pytest.raises(CoreError) as caught:
        Store.open(cfg,str(cfg.repo_path/".git"))
    assert caught.value.code=="CONFIGURATION_ERROR"
    assert target.read_bytes()==b"preserve exact bytes" and link.is_symlink()
